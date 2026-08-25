#include <metal_stdlib>
using namespace metal;

// 카메라 좌표계 노트: `poses.jsonl`의 `camera_transform`은 ARKit의 OpenGL 스타일
// 컨벤션(Y-up, 카메라 로컬 -Z가 전방)이다. `intrinsics`(fx,fy,cx,cy)는 그와 별개로
// 표준 컴퓨터비전 픽셀 컨벤션(x-right, y-down, z-forward)을 가정한다 — 그래서
// world -> pixel 변환은 반드시 GL_TO_CV = diag(1,-1,-1,1) 축 반전을 거쳐야 한다
// (dc-vps-digital-twin의 COLMAP 변환 스크립트에서 실측으로 검증된 컨벤션과 동일).
// `TextureBaker.swift`가 view 행렬을 만들 때 이미 이 반전을 포함시켜서 넘긴다 —
// 즉 아래 셰이더에서 camera-space 좌표는 항상 z>0가 카메라 전방이다.

// CPU(Swift)와 이 구조체의 메모리 레이아웃을 손으로 맞춰야 하는데(이 환경에서
// Metal/Swift를 컴파일해서 검증할 방법이 없다), MSL의 float3/float4x4는 struct
// 멤버로 쓰일 때 암묵적 정렬 패딩이 붙는다(float3 -> 16바이트, float4x4는 각 컬럼이
// float4 정렬) — 그 규칙을 손으로 재현하다 어긋나는 위험을 아예 없애기 위해, 모든
// 필드를 plain float 스칼라로만 선언한다(스칼라 float 배열/필드는 두 언어 모두
// 패딩 없이 4바이트 그대로 연속 배치되는 게 보장됨). 행렬은 column-major
// float[16](m[col*4+row])로 넘기고 함수 안에서 float4x4로 재구성한다.
struct CameraUniforms {
    float viewMatrix[16];       // world -> camera-space(CV 컨벤션, z>0 전방), column-major
    float depthProjection[16];  // depth pre-pass용 camera-space -> clip(0..1 depth), column-major
    float cameraWorldPosX, cameraWorldPosY, cameraWorldPosZ;
    float fx, fy, cx, cy;      // 원본(raw landscape) 해상도 기준 intrinsics
    float imageWidth, imageHeight;
    float blendPower;
    float occlusionBias;       // depth 비교 시 self-occlusion을 막기 위한 여유값
};

static inline float4x4 loadMatrix(constant float *m) {
    return float4x4(
        float4(m[0], m[1], m[2], m[3]),
        float4(m[4], m[5], m[6], m[7]),
        float4(m[8], m[9], m[10], m[11]),
        float4(m[12], m[13], m[14], m[15])
    );
}

// MARK: - Pass A: depth pre-pass (occlusion 판정용, 카메라 실제 시점에서 렌더)

struct DepthPrepassVertexOut {
    float4 position [[position]];
};

vertex DepthPrepassVertexOut depthPrepassVertex(
    const device packed_float3 *positions [[buffer(0)]],
    constant CameraUniforms &camera [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    float3 worldPos = float3(positions[vertexID]);
    float4x4 view = loadMatrix(camera.viewMatrix);
    float4x4 proj = loadMatrix(camera.depthProjection);
    float3 camPos = (view * float4(worldPos, 1.0)).xyz;
    DepthPrepassVertexOut out;
    out.position = proj * float4(camPos, 1.0);
    return out;
}

// fragment 없음 — 깊이만 필요하므로 fragment function 자체를 파이프라인에 안 붙인다
// (Swift 쪽에서 fragmentFunction = nil로 depth-only 파이프라인을 만든다).

// MARK: - Pass B: UV 공간에서의 텍스처 누적 베이킹
//
// 표준 "UV 공간 베이킹" 트릭: 정점을 카메라가 아니라 그 삼각형의 UV 아틀라스 좌표에
// 그대로 그린다(clip = uv*2-1, 정사영). 그러면 렌더 타겟이 곧 텍스처 아틀라스가 되고,
// fragment shader에서 world position을 보간해서 "지금 처리 중인 카메라"로 재투영,
// 사진을 샘플링해서 additive blending으로 누적한다 — atomic 연산 없이 GPU 블렌딩만으로
// 여러 카메라의 기여가 쌓인다.

struct AtlasBakeVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
};

vertex AtlasBakeVertexOut atlasBakeVertex(
    const device packed_float3 *positions [[buffer(0)]],
    const device packed_float3 *normals [[buffer(1)]],
    const device packed_float2 *uvs [[buffer(2)]],
    uint vertexID [[vertex_id]]
) {
    AtlasBakeVertexOut out;
    float2 uv = float2(uvs[vertexID]);
    // UV(0,0)=좌상단을 clip(-1,+1)에 대응시킨다(표준 Metal 텍스처 v-방향 뒤집기).
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.worldPos = float3(positions[vertexID]);
    out.normal = float3(normals[vertexID]);
    return out;
}

struct AtlasBakeFragmentOut {
    float4 accumColor [[color(0)]]; // color*weight 누적
    float accumWeight [[color(1)]];
};

fragment AtlasBakeFragmentOut atlasBakeFragment(
    AtlasBakeVertexOut in [[stage_in]],
    constant CameraUniforms &camera [[buffer(0)]],
    texture2d<float> photo [[texture(0)]],
    depth2d<float> occlusionDepth [[texture(1)]]
) {
    AtlasBakeFragmentOut out;
    out.accumColor = float4(0.0);
    out.accumWeight = 0.0;

    float4x4 view = loadMatrix(camera.viewMatrix);
    float3 camPos = (view * float4(in.worldPos, 1.0)).xyz;
    if (camPos.z <= 0.001) {
        return out; // 카메라 뒤
    }

    float pixelX = camera.fx * camPos.x / camPos.z + camera.cx;
    float pixelY = camera.fy * camPos.y / camPos.z + camera.cy;
    if (pixelX < 0.0 || pixelX >= camera.imageWidth || pixelY < 0.0 || pixelY >= camera.imageHeight) {
        return out; // 이미지 범위 밖
    }

    // occlusion 체크: depth pre-pass와 동일한 투영으로 depth 텍스처 좌표를 구한다.
    // depthProjection이 이미 (u,v) = (pixelX/imageWidth, pixelY/imageHeight)와 같은
    // 정규화 좌표를 만들도록 만들어져 있으므로(TextureBaker.swift 참고) 그대로 재사용.
    float2 depthUV = float2(pixelX / camera.imageWidth, pixelY / camera.imageHeight);
    constexpr sampler depthSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
    float storedDepth = occlusionDepth.sample(depthSampler, depthUV);
    // depthProjection의 row2(A,B)만 필요: column-major m[col*4+row]에서 A=m[2*4+2]=m[10], B=m[3*4+2]=m[14].
    float thisDepthNDC = camera.depthProjection[10] + camera.depthProjection[14] / camPos.z; // A + B/z, w-divide 후 값
    if (thisDepthNDC > storedDepth + camera.occlusionBias) {
        return out; // 다른 표면에 가려짐
    }

    float3 cameraWorldPos = float3(camera.cameraWorldPosX, camera.cameraWorldPosY, camera.cameraWorldPosZ);
    float3 toCam = cameraWorldPos - in.worldPos;
    float dist = max(length(toCam), 1e-4);
    float3 viewDir = toCam / dist;
    float3 normal = normalize(in.normal);
    float cosAngle = max(dot(normal, viewDir), 0.0);
    float score = cosAngle / dist;
    float weight = pow(max(score, 1e-8), camera.blendPower);

    constexpr sampler photoSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 photoUV = float2(pixelX / camera.imageWidth, pixelY / camera.imageHeight);
    float3 color = photo.sample(photoSampler, photoUV).rgb;

    out.accumColor = float4(color * weight, weight);
    out.accumWeight = weight;
    return out;
}

// MARK: - 정규화 패스: accumColor / accumWeight (weight>0인 텍셀만)

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut fullscreenQuadVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
    FullscreenVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 normalizeAtlasFragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> accumColor [[texture(0)]],
    texture2d<float> accumWeight [[texture(1)]]
) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float4 colorSum = accumColor.sample(s, in.uv);
    float weightSum = accumWeight.sample(s, in.uv).r;
    if (weightSum <= 1e-8) {
        return float4(0.0, 0.0, 0.0, 0.0); // alpha=0 -> "아직 안 보임" 마커, CPU에서 홀 채우기
    }
    return float4(colorSum.rgb / weightSum, 1.0);
}
