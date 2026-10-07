/**
 * A rebuild of the Mac app's Mixer panel for video.
 *
 * It is a likeness, not the real view: the copy, colours and point metrics come
 * from DESIGN.md and PopoverController.swift, but the layout is computed here
 * so the routing rail can be drawn from the same numbers as the rows.
 */

import React from "react";
import { color, font, metric, PANEL_WIDTH } from "./tokens";

export type IconKind = "laptop" | "homepod" | "appletv" | "speaker";

export type DeviceModel = {
  id: string;
  name: string;
  icon: IconKind;
  /** 0 = idle, 1 = playing your audio. Animate it to light the row up. */
  live: number;
  /** 0–100, the device's own level. */
  volume: number;
  /** The Source column pill, or null while the speaker is idle. */
  source?: string | null;
  /** 0–1 playback level for the meter under the name. */
  meter?: number;
};

export type MixerModel = {
  /** Text on the Main Audio row's destination button. */
  destination: string;
  mainVolume: number;
  devices: DeviceModel[];
  /** Index in `devices` where the "AirPlay Speakers" subsection starts. */
  airplayFrom: number;
  /** The first-run hint under the Output Speakers header. */
  hint?: string | null;
  /** Fade the hint out without collapsing its slot, so nothing reflows. */
  hintOpacity?: number;
};

const H = {
  cardHeader: 30,
  subsection: 24,
  row: metric.rowHeight,
  note: 26,
  cardGap: 16,
  plus: 26,
  padTop: 10,
  padBottom: 12,
} as const;

type Placed =
  | { kind: "cardHeader"; y: number; title: string; trailing: string }
  | { kind: "subsection"; y: number; title: string }
  | { kind: "note"; y: number; text: string; opacity: number }
  | {
      kind: "row";
      y: number;
      device: DeviceModel;
      main?: boolean;
      destination?: string;
    }
  | { kind: "rule"; y: number }
  | { kind: "plus"; y: number };

/** Walk the model once, giving every element a y in points. */
export const layout = (model: MixerModel) => {
  const items: Placed[] = [];
  let y = H.padTop;

  items.push({
    kind: "cardHeader",
    y,
    title: "System Audio",
    trailing: "Output",
  });
  y += H.cardHeader;
  const mainY = y;
  items.push({
    kind: "row",
    y,
    main: true,
    destination: model.destination,
    device: {
      id: "main",
      name: "Main Audio",
      icon: "laptop",
      live: 1,
      volume: model.mainVolume,
    },
  });
  y += H.row + H.cardGap;

  items.push({ kind: "rule", y });
  y += H.cardGap;

  items.push({
    kind: "cardHeader",
    y,
    title: "Output Speakers",
    trailing: "Source",
  });
  y += H.cardHeader;

  if (model.hint) {
    items.push({
      kind: "note",
      y,
      text: model.hint,
      opacity: model.hintOpacity ?? 1,
    });
    y += H.note;
  }

  model.devices.forEach((device, index) => {
    if (index === model.airplayFrom) {
      items.push({ kind: "subsection", y, title: "AirPlay Speakers" });
      y += H.subsection;
    }
    items.push({ kind: "row", y, device });
    y += H.row;
  });

  y += 6;
  const plusY = y;
  items.push({ kind: "plus", y });
  y += H.plus;

  return { items, height: y + H.padBottom, mainY, plusY };
};

/* ------------------------------------------------------------------ icons */

const Icon: React.FC<{ kind: IconKind; live: number }> = ({ kind, live }) => {
  const stroke = mix(color.labelCool2, color.glow, live);
  const common = {
    fill: "none",
    stroke,
    strokeWidth: 1.4,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };
  return (
    <svg width={18} height={18} viewBox="0 0 18 18">
      {kind === "laptop" ? (
        <>
          <rect x={2.5} y={3.5} width={13} height={8.5} rx={1.2} {...common} />
          <path d="M1 14h16" {...common} />
        </>
      ) : null}
      {kind === "homepod" ? (
        <>
          <rect x={4.5} y={2.5} width={9} height={13} rx={4} {...common} />
          <path d="M6.5 6.5h5" {...common} />
        </>
      ) : null}
      {kind === "appletv" ? (
        <>
          <rect x={2.5} y={3} width={13} height={12} rx={2.4} {...common} />
          <path d="M7 7.5v3l3-1.5z" {...common} />
        </>
      ) : null}
      {kind === "speaker" ? (
        <>
          <rect x={4} y={2.5} width={10} height={13} rx={2} {...common} />
          <circle cx={9} cy={11} r={2.4} {...common} />
          <circle cx={9} cy={5.6} r={1} {...common} />
        </>
      ) : null}
    </svg>
  );
};

/** The icon well: a halo ring and a state dot appear as the speaker goes live. */
const IconWell: React.FC<{ kind: IconKind; live: number }> = ({
  kind,
  live,
}) => (
  <div
    style={{
      position: "relative",
      width: metric.iconWidth,
      height: metric.iconWidth,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      flex: "none",
    }}
  >
    <div
      style={{
        position: "absolute",
        inset: 0,
        borderRadius: "50%",
        border: `1.4px solid ${color.gold}`,
        opacity: live,
        scale: 0.86 + 0.14 * live,
        boxShadow: `0 0 ${10 * live}px ${color.gold}55`,
      }}
    />
    <Icon kind={kind} live={live} />
    <div
      style={{
        position: "absolute",
        right: -1,
        bottom: -1,
        width: 6,
        height: 6,
        borderRadius: "50%",
        backgroundColor: mix(color.well, color.gold, live),
        boxShadow: `0 0 ${6 * live}px ${color.glow}`,
      }}
    />
  </div>
);

/* ----------------------------------------------------------------- pieces */

const Meter: React.FC<{ live: number; level: number }> = ({ live, level }) => (
  <div
    style={{
      position: "relative",
      marginTop: 3,
      height: 2,
      width: metric.nameWidth,
      borderRadius: 1,
      backgroundColor: color.socket,
    }}
  >
    <div
      style={{
        position: "absolute",
        inset: 0,
        width: `${Math.max(6, level * 100)}%`,
        borderRadius: 1,
        backgroundColor: mix(color.meter, color.gold, live),
      }}
    />
  </div>
);

const Slider: React.FC<{ value: number; live: number }> = ({ value, live }) => {
  const fill = mix(color.ember, color.gold, live);
  const knob = 11;
  const travel = metric.sliderWidth - knob;
  return (
    <div
      style={{
        position: "relative",
        width: metric.sliderWidth,
        height: knob,
        flex: "none",
      }}
    >
      <div
        style={{
          position: "absolute",
          top: (knob - 3) / 2,
          left: 0,
          right: 0,
          height: 3,
          borderRadius: 1.5,
          backgroundColor: color.socket,
        }}
      />
      <div
        style={{
          position: "absolute",
          top: (knob - 3) / 2,
          left: 0,
          width: (value / 100) * travel + knob / 2,
          height: 3,
          borderRadius: 1.5,
          backgroundColor: fill,
          boxShadow: `0 0 ${5 * live}px ${color.gold}66`,
        }}
      />
      <div
        style={{
          position: "absolute",
          top: 0,
          left: (value / 100) * travel,
          width: knob,
          height: knob,
          borderRadius: knob / 2,
          backgroundColor: mix("#6E6250", color.glow, live),
          boxShadow: `0 1px 2px #000A, 0 0 ${8 * live}px ${color.gold}55`,
        }}
      />
    </div>
  );
};

const SourcePill: React.FC<{ text: string; live: number }> = ({
  text,
  live,
}) => (
  <div
    style={{
      width: metric.trailingWidth,
      display: "flex",
      justifyContent: "flex-start",
      flex: "none",
    }}
  >
    <div
      style={{
        opacity: live,
        padding: "2.5px 7px",
        borderRadius: 5,
        backgroundColor: color.raised,
        color: color.label2,
        fontSize: font.caption,
        fontWeight: 500,
        whiteSpace: "nowrap",
      }}
    >
      {text}
    </div>
  </div>
);

const Row: React.FC<{ item: Extract<Placed, { kind: "row" }> }> = ({
  item,
}) => {
  const d = item.device;
  const live = d.live;
  return (
    <div
      style={{
        position: "absolute",
        top: item.y,
        left: metric.railGutter,
        width: PANEL_WIDTH - metric.railGutter,
        height: metric.rowHeight,
        display: "flex",
        alignItems: "center",
        gap: 8,
        paddingLeft: metric.inset,
        paddingRight: metric.inset,
        boxSizing: "border-box",
        borderRadius: metric.rowRadius,
        backgroundColor: `rgba(46, 37, 24, ${0.55 * live})`,
      }}
    >
      <IconWell kind={d.icon} live={live} />
      <div style={{ width: metric.nameWidth, marginLeft: 2, flex: "none" }}>
        <div
          style={{
            fontSize: font.name,
            fontWeight: live > 0.5 ? 600 : 400,
            color: mix(color.labelCool, color.label, live),
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
          }}
        >
          {d.name}
        </div>
        <Meter live={live} level={d.meter ?? 0.35} />
      </div>
      <Slider value={d.volume} live={live} />
      <div
        style={{
          width: metric.readoutWidth,
          textAlign: "right",
          fontSize: font.caption,
          fontWeight: 600,
          fontVariantNumeric: "tabular-nums",
          color: mix(color.emberText, color.goldText, live),
          whiteSpace: "nowrap",
          flex: "none",
        }}
      >
        {Math.round(d.volume)} %
      </div>
      {item.main ? (
        <MainDestination text={item.destination ?? "Selected Speakers"} />
      ) : (
        <SourcePill text={d.source ?? "System"} live={live} />
      )}
    </div>
  );
};

/**
 * The Main Audio row's destination button — the app's actual routing control.
 * It reads "Selected Speakers" for the set composed below, or "→ Name" once a
 * saved scene is the target.
 */
const MainDestination: React.FC<{ text: string }> = ({ text }) => (
  <div
    style={{
      width: metric.trailingWidth,
      height: 22,
      flex: "none",
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      padding: "0 5px 0 8px",
      boxSizing: "border-box",
      borderRadius: 6,
      backgroundColor: color.raised,
      border: `0.5px solid ${color.containerEdge}`,
      color: color.label,
      fontSize: font.body,
      fontWeight: 500,
      whiteSpace: "nowrap",
    }}
  >
    <span>{text}</span>
    <svg width={9} height={14} viewBox="0 0 9 14">
      <path
        d="M1.5 5.5L4.5 2l3 3.5M1.5 8.5l3 3.5 3-3.5"
        fill="none"
        stroke={color.labelCool}
        strokeWidth={1.3}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  </div>
);

/* ------------------------------------------------------------------- rail */

/**
 * The routing rail: one node per speaker row, filled while that speaker is
 * carrying your audio, and a gold line running from Main Audio down to the
 * last one that is.
 */
const Rail: React.FC<{
  nodes: { y: number; live: number }[];
  mainY: number;
  height: number;
}> = ({ nodes, mainY, height }) => {
  const cx = 16;
  const originY = mainY + metric.rowHeight / 2;
  const lastLive = nodes.reduce(
    (acc, n) => (n.live > 0.5 ? n.y + metric.rowHeight / 2 : acc),
    originY,
  );
  return (
    <svg
      width={metric.railGutter}
      height={height}
      style={{ position: "absolute", top: 0, left: 0 }}
    >
      <path
        d={`M ${cx} ${originY} L ${cx} ${lastLive}`}
        stroke={color.gold}
        strokeWidth={2}
        fill="none"
        strokeLinecap="round"
      />
      <circle cx={cx} cy={originY} r={7} fill={color.gold} />
      {nodes.map((n, i) => {
        const y = n.y + metric.rowHeight / 2;
        return (
          <g key={i}>
            <circle
              cx={cx}
              cy={y}
              r={7}
              fill={color.canvas}
              stroke={color.gold}
              strokeWidth={1.6}
            />
            <circle
              cx={cx}
              cy={y}
              r={7 * n.live}
              fill={color.gold}
              opacity={n.live}
            />
          </g>
        );
      })}
    </svg>
  );
};

/* ------------------------------------------------------------------ panel */

export const Mixer: React.FC<{ model: MixerModel }> = ({ model }) => {
  const { items, height, mainY } = layout(model);
  const nodes = items
    .filter((i): i is Extract<Placed, { kind: "row" }> => i.kind === "row")
    .filter((i) => !i.main)
    .map((i) => ({ y: i.y, live: i.device.live }));

  return (
    <div
      style={{
        position: "relative",
        width: PANEL_WIDTH,
        height,
        borderRadius: metric.panelRadius,
        backgroundColor: color.panel,
        border: `1px solid ${color.hairline}`,
        boxShadow: "0 24px 60px #000C, 0 2px 8px #0008",
        fontFamily: font.ui,
        overflow: "hidden",
      }}
    >
      <Rail nodes={nodes} mainY={mainY} height={height} />
      {items.map((item, i) => {
        if (item.kind === "row") return <Row key={i} item={item} />;
        if (item.kind === "rule")
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                top: item.y,
                left: metric.railGutter + metric.inset,
                right: metric.inset,
                height: 1,
                backgroundColor: color.hairline,
              }}
            />
          );
        if (item.kind === "plus")
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                top: item.y,
                left: metric.railGutter + metric.inset,
                width: 26,
                height: 22,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                borderRadius: 6,
                border: `0.5px solid ${color.containerEdge}`,
                backgroundColor: color.raised,
              }}
            >
              <svg width={11} height={11} viewBox="0 0 11 11">
                <path
                  d="M5.5 1v9M1 5.5h9"
                  stroke={color.labelCool}
                  strokeWidth={1.4}
                  strokeLinecap="round"
                />
              </svg>
            </div>
          );
        if (item.kind === "note")
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                top: item.y,
                left: metric.railGutter + metric.inset + 4,
                right: metric.inset,
                fontSize: font.caption,
                lineHeight: "14px",
                color: color.labelCool2,
                opacity: item.opacity,
              }}
            >
              {item.text}
            </div>
          );
        if (item.kind === "subsection")
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                top: item.y,
                left: metric.railGutter + metric.inset + 4,
                right: metric.inset,
                height: H.subsection,
                display: "flex",
                alignItems: "center",
                fontSize: font.caption,
                fontWeight: 500,
                color: color.labelCool2,
              }}
            >
              {item.title}
            </div>
          );
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              top: item.y,
              left: metric.railGutter + metric.inset,
              right: metric.inset,
              height: H.cardHeader,
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              fontSize: font.body,
              fontWeight: 600,
              color: color.label,
            }}
          >
            <span>{item.title}</span>
            <span
              style={{
                fontSize: font.micro,
                fontWeight: 600,
                color: color.labelCool2,
              }}
            >
              {item.trailing}
            </span>
          </div>
        );
      })}
    </div>
  );
};

/* ------------------------------------------------------------------ utils */

const hex = (c: string) => [
  parseInt(c.slice(1, 3), 16),
  parseInt(c.slice(3, 5), 16),
  parseInt(c.slice(5, 7), 16),
];

/** Blend two hex colours. `t` of 0 returns `a`, 1 returns `b`. */
export const mix = (a: string, b: string, t: number) => {
  const clamped = Math.max(0, Math.min(1, t));
  const [ar, ag, ab] = hex(a);
  const [br, bg, bb] = hex(b);
  const at = (x: number, y: number) => Math.round(x + (y - x) * clamped);
  return `rgb(${at(ar, br)}, ${at(ag, bg)}, ${at(ab, bb)})`;
};
