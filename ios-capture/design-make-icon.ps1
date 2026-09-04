Add-Type -AssemblyName System.Drawing

$outDir = "$PSScriptRoot\icons"
New-Item -ItemType Directory -Force $outDir | Out-Null

function New-Icon {
    param(
        [string]$OutFile,
        [string]$Bg, [string]$Letter, [string]$MeshLine, [string]$Dot, [string]$Accent
    )
    $size = 1024
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml($Bg))

    # Letter path: big geometric "S", centered by its actual bounds.
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $family = $null
    foreach ($name in @("Bahnschrift", "Segoe UI Black", "Arial Black")) {
        try { $family = New-Object System.Drawing.FontFamily $name; break } catch {}
    }
    $style = [System.Drawing.FontStyle]::Bold
    $fmt = New-Object System.Drawing.StringFormat
    $path.AddString("S", $family, [int]$style, 820, (New-Object System.Drawing.PointF 0, 0), $fmt)
    $b = $path.GetBounds()
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $m.Translate(($size - $b.Width) / 2 - $b.X, ($size - $b.Height) / 2 - $b.Y)
    $path.Transform($m)

    # Fill letter.
    $letterBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Letter))
    $g.FillPath($letterBrush, $path)

    # Triangulated mesh, clipped to the letter: a slightly jittered triangular lattice.
    $g.SetClip($path)
    $linePen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($MeshLine)), 4
    $linePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $dotBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Dot))
    $rand = New-Object System.Random 11
    $step = 92
    $rows = [int]($size / ($step * 0.866)) + 3
    $cols = [int]($size / $step) + 3
    $pts = @{}
    for ($r = -1; $r -lt $rows; $r++) {
        for ($c = -1; $c -lt $cols; $c++) {
            $x = $c * $step + ($(if ($r % 2 -eq 0) { 0 } else { $step / 2 })) + ($rand.NextDouble() - 0.5) * 24
            $y = $r * $step * 0.866 + ($rand.NextDouble() - 0.5) * 24
            $pts["$r,$c"] = New-Object System.Drawing.PointF $x, $y
        }
    }
    for ($r = -1; $r -lt $rows - 1; $r++) {
        for ($c = -1; $c -lt $cols - 1; $c++) {
            $p = $pts["$r,$c"]
            $right = $pts["$r,$($c+1)"]
            $g.DrawLine($linePen, $p, $right)
            $dl = if ($r % 2 -eq 0) { $pts["$($r+1),$($c-1)"] } else { $pts["$($r+1),$c"] }
            $dr = if ($r % 2 -eq 0) { $pts["$($r+1),$c"] } else { $pts["$($r+1),$($c+1)"] }
            if ($dl) { $g.DrawLine($linePen, $p, $dl) }
            if ($dr) { $g.DrawLine($linePen, $p, $dr) }
        }
    }
    foreach ($p in $pts.Values) {
        $g.FillEllipse($dotBrush, $p.X - 6, $p.Y - 6, 12, 12)
    }
    $g.ResetClip()

    # Thin outline so the letter reads crisply against the mesh.
    $outlinePen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($Letter)), 10
    $outlinePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($outlinePen, $path)

    # Small scan-frame corner accents (nod to the previous icon), well inside the safe area.
    $accentPen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($Accent)), 14
    $accentPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $accentPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $inset = 118; $len = 90
    $lo = $inset; $hi = $size - $inset; $loL = $inset + $len; $hiL = $size - $inset - $len
    # PowerShell: ',' binds tighter than '+', so arithmetic inside array literals must be pre-computed.
    $corners = @(
        @(@($lo, $loL), @($lo, $lo), @($loL, $lo)),
        @(@($hiL, $lo), @($hi, $lo), @($hi, $loL)),
        @(@($lo, $hiL), @($lo, $hi), @($loL, $hi)),
        @(@($hiL, $hi), @($hi, $hi), @($hi, $hiL))
    )
    foreach ($c in $corners) {
        $g.DrawLine($accentPen, [float]$c[0][0], [float]$c[0][1], [float]$c[1][0], [float]$c[1][1])
        $g.DrawLine($accentPen, [float]$c[1][0], [float]$c[1][1], [float]$c[2][0], [float]$c[2][1])
    }

    $g.Dispose()
    $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output "wrote $OutFile (font: $($family.Name))"
}

New-Icon -OutFile "$outDir\AppIcon-1024.png"        -Bg "#0B1220" -Letter "#4FD1C5" -MeshLine "#0F3D3A" -Dot "#E6FFFA" -Accent "#2A7F79"
New-Icon -OutFile "$outDir\AppIcon-1024-dark.png"   -Bg "#04070E" -Letter "#5EEAD4" -MeshLine "#0E3532" -Dot "#F0FFFC" -Accent "#2A7F79"
New-Icon -OutFile "$outDir\AppIcon-1024-tinted.png" -Bg "#262626" -Letter "#F2F2F2" -MeshLine "#8A8A8A" -Dot "#FFFFFF" -Accent "#9C9C9C"
