# Ideogram 4

Ideogram 4 is a structured-caption model: instead of a single prompt string it
takes a JSON caption describing a high-level scene, an optional style block, and
a compositional breakdown of regional elements (each with an optional bounding
box and color palette).

- **Caption editor** — author the structured caption in a sectioned form, or let
  Gemma turn a plain description into a full caption (`mlx_lm` runs locally on
  the bundled Python; no API key).
- **Bounding-box layout editor** — drag, resize, and color regional elements on a
  canvas overlaid on the output aspect ratio.
- **Color palettes** — per-element and per-style palettes with editable hex entry,
  so an exact color can be reused across elements.
- **Precision** — BF16 / Q8 / Q4 selector. Each loads its
  `mflux-community/ideogram-4-mflux-*` repo directly; Q8/Q4 are pre-quantized.

> **Before first use:** the Q8 and Q4 repos are gated on HuggingFace, so accept the
> terms on the repo page before the first download (BF16 is not gated). The bundled mflux supports it. With a
> Custom Python (DMG only), any model whose CLI is missing from that install is
> disabled in the model picker with a note saying so.
