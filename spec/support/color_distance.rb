# Perceptual color distance for theme specs (inspector-headers-1): CIEDE2000
# between two sRGB [r, g, b] colors, and WCAG 2 contrast.  A heading color
# within about 10 of an ordinary role reads as that role (the default
# theme's FILTER band blue was 7.4 from :title, its AMP green 7.2 from :ok).
module ColorDistance
  module_function

  def linear(v)
    v /= 255.0
    v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4
  end

  def luminance(rgb)
    r, g, b = rgb.map { |v| linear(v) }
    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  # WCAG 2 contrast ratio (1 to 21).
  def contrast(a, b)
    hi, lo = [luminance(a), luminance(b)].sort.reverse
    (hi + 0.05) / (lo + 0.05)
  end

  # CIELAB (D65).
  def lab(rgb)
    r, g, b = rgb.map { |v| linear(v) }
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = ->(t) { t > 0.008856 ? t**(1.0 / 3) : 7.787 * t + 16.0 / 116 }
    [116 * f.(y) - 16, 500 * (f.(x) - f.(y)), 200 * (f.(y) - f.(z))]
  end

  # CIEDE2000 (Sharma, Wu, Dalal 2005).
  def delta_e(c1, c2)
    l1, a1, b1 = lab(c1)
    l2, a2, b2 = lab(c2)
    rad = Math::PI / 180
    cm = (Math.hypot(a1, b1) + Math.hypot(a2, b2)) / 2
    g = 0.5 * (1 - Math.sqrt(cm**7 / (cm**7 + 25.0**7)))
    a1p = a1 * (1 + g)
    a2p = a2 * (1 + g)
    c1p = Math.hypot(a1p, b1)
    c2p = Math.hypot(a2p, b2)
    hue = ->(b, a) { a == 0 && b == 0 ? 0.0 : (Math.atan2(b, a) / rad) % 360 }
    h1 = hue.(b1, a1p)
    h2 = hue.(b2, a2p)
    dh = if c1p * c2p == 0 then 0.0
         elsif (h2 - h1).abs <= 180 then h2 - h1
         elsif h2 - h1 > 180 then h2 - h1 - 360
         else h2 - h1 + 360
         end
    dl = l2 - l1
    dc = c2p - c1p
    dhh = 2 * Math.sqrt(c1p * c2p) * Math.sin(dh * rad / 2)
    lm = (l1 + l2) / 2
    cpm = (c1p + c2p) / 2
    hm = if c1p * c2p == 0 then h1 + h2
         elsif (h1 - h2).abs <= 180 then (h1 + h2) / 2
         elsif h1 + h2 < 360 then (h1 + h2 + 360) / 2
         else (h1 + h2 - 360) / 2
         end
    t = 1 - 0.17 * Math.cos((hm - 30) * rad) + 0.24 * Math.cos(2 * hm * rad) +
        0.32 * Math.cos((3 * hm + 6) * rad) - 0.2 * Math.cos((4 * hm - 63) * rad)
    sl = 1 + 0.015 * (lm - 50)**2 / Math.sqrt(20 + (lm - 50)**2)
    sc = 1 + 0.045 * cpm
    sh = 1 + 0.015 * cpm * t
    rt = -Math.sin(2 * 30 * Math.exp(-(((hm - 275) / 25)**2)) * rad) * 2 * Math.sqrt(cpm**7 / (cpm**7 + 25.0**7))
    Math.sqrt((dl / sl)**2 + (dc / sc)**2 + (dhh / sh)**2 + rt * (dc / sc) * (dhh / sh))
  end
end
