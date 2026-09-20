/** Pointer, menus and captions laid over the rebuilt Mixer panel. */

import React from "react";
import { color, font } from "./tokens";

/** The macOS arrow, drawn in panel points so it scales with the camera. */
export const Cursor: React.FC<{ x: number; y: number; press: number }> = ({
  x,
  y,
  press,
}) => (
  <svg
    width={15}
    height={22}
    viewBox="0 0 15 22"
    style={{
      position: "absolute",
      left: x,
      top: y,
      scale: 1 - 0.12 * press,
      transformOrigin: "2px 2px",
      filter: "drop-shadow(0 1px 2px #0009)",
      zIndex: 40,
    }}
  >
    <path
      d="M1.5 1.2v15.2l3.9-3.8h5.4z"
      fill="#FFFFFF"
      stroke="#1A1A1A"
      strokeWidth={1.1}
      strokeLinejoin="round"
    />
  </svg>
);

/** The gold ripple a click leaves behind. */
export const ClickRing: React.FC<{ x: number; y: number; t: number }> = ({
  x,
  y,
  t,
}) => (
  <div
    style={{
      position: "absolute",
      left: x - 16,
      top: y - 16,
      width: 32,
      height: 32,
      borderRadius: "50%",
      border: `1.5px solid ${color.gold}`,
      opacity: Math.max(0, 1 - t),
      scale: 0.3 + t * 1.1,
      zIndex: 35,
      pointerEvents: "none",
    }}
  />
);

export type MenuEntry = { title: string; header?: boolean; checked?: boolean };

/** An AppKit pop-up menu, in panel points. */
export const Menu: React.FC<{
  x: number;
  y: number;
  width: number;
  entries: MenuEntry[];
  /** Index of the entry under the pointer, or -1. */
  highlight: number;
  reveal: number;
}> = ({ x, y, width, entries, highlight, reveal }) => (
  <div
    style={{
      position: "absolute",
      left: x,
      top: y,
      width,
      padding: "4px 0",
      borderRadius: 8,
      backgroundColor: "rgba(41, 43, 47, 0.995)",
      border: "0.5px solid rgba(255,255,255,0.14)",
      boxShadow: "0 12px 34px #000C",
      fontFamily: font.ui,
      opacity: reveal,
      scale: 0.96 + 0.04 * reveal,
      transformOrigin: "top left",
      overflow: "hidden",
      zIndex: 30,
    }}
  >
    {entries.map((entry, i) => (
      <div
        key={i}
        style={{
          height: entry.header ? 18 : 21,
          display: "flex",
          alignItems: "center",
          padding: "0 9px 0 20px",
          margin: "0 4px",
          borderRadius: 4,
          backgroundColor: i === highlight ? color.gold : "transparent",
          color: entry.header
            ? color.labelCool2
            : i === highlight
              ? color.inkOnFill
              : "#ECECEE",
          fontSize: entry.header ? font.micro : font.body,
          fontWeight: entry.header ? 600 : 400,
          whiteSpace: "nowrap",
          position: "relative",
        }}
      >
        {entry.checked ? (
          <span
            style={{
              position: "absolute",
              left: 7,
              fontSize: font.caption,
              color: i === highlight ? color.inkOnFill : "#ECECEE",
            }}
          >
            ✓
          </span>
        ) : null}
        {entry.title}
      </div>
    ))}
  </div>
);

/** The one line of copy carrying each beat, above the panel. */
export const Caption: React.FC<{
  text: string;
  accent?: string;
  opacity: number;
  lift: number;
}> = ({ text, accent, opacity, lift }) => (
  <div
    style={{
      position: "absolute",
      left: 90,
      right: 90,
      top: 300,
      textAlign: "center",
      fontFamily: font.ui,
      opacity,
      translate: `0px ${lift}px`,
    }}
  >
    <div
      style={{
        fontSize: 72,
        lineHeight: "84px",
        fontWeight: 600,
        letterSpacing: "-0.02em",
        color: "#F7F6F4",
      }}
    >
      {text}
    </div>
    {accent ? (
      <div
        style={{
          marginTop: 22,
          fontSize: 40,
          lineHeight: "50px",
          fontWeight: 400,
          color: color.label2,
        }}
      >
        {accent}
      </div>
    ) : null}
  </div>
);
