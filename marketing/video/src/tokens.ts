/**
 * Colours and metrics copied from the Mac app's DESIGN.md front matter.
 * Keep these in step with that file — it is the authority, this is a copy.
 */

export const color = {
  canvas: "#0A0A0C",
  panel: "#15171A",
  raised: "#1F232A",
  well: "#050507",
  liveRow: "#2E2518",
  liveRaised: "#2B241C",
  label: "#F2F2F4",
  label2: "#B7AC95",
  label3: "#9E947F",
  labelCool: "#A9B3BB",
  labelCool2: "#818C94",
  hairline: "#2A2E33",
  containerEdge: "#3D4247",
  rim: "#6B767D",
  gold: "#E8B84B",
  goldText: "#E8B84B",
  glow: "#FFD97A",
  ember: "#8A6A2F",
  emberText: "#A98341",
  inkOnFill: "#171104",
  meter: "#464C55",
  socket: "#2A2E33",
  bluetoothBrand: "#0082FC",
} as const;

/** Point metrics from DESIGN.md `spacing` / `rounded`. */
export const metric = {
  railGutter: 30,
  inset: 14,
  rowHeight: 42,
  iconWidth: 26,
  nameWidth: 160,
  sliderWidth: 70,
  readoutWidth: 40,
  /** The trailing control column: the destination button and the Source pills. */
  trailingWidth: 124,
  rowRadius: 16,
  panelRadius: 12,
  controlRadius: 10,
} as const;

/** Natural width of the rebuilt mixer panel, in points. */
export const PANEL_WIDTH =
  metric.railGutter +
  metric.inset +
  metric.iconWidth +
  10 +
  metric.nameWidth +
  8 +
  metric.sliderWidth +
  8 +
  metric.readoutWidth +
  8 +
  metric.trailingWidth +
  metric.inset;

export const font = {
  ui: '-apple-system, "SF Pro Text", "Helvetica Neue", sans-serif',
  body: 13,
  name: 13,
  caption: 11,
  micro: 10,
} as const;
