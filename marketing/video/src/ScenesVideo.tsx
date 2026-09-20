/**
 * "Scenes" — save a set of speakers, bring it back with one click.
 *
 * One continuous take: the panel never unmounts, every element reads the same
 * frame, and the captions ride over the top. Beat frames live in `BEAT` below,
 * so retiming the video means moving numbers there and nothing else.
 */

import React from "react";
import {
  AbsoluteFill,
  Easing,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { color, font, PANEL_WIDTH } from "./tokens";
import { DeviceModel, layout, Mixer, MixerModel } from "./mixer";
import { Caption, ClickRing, Cursor, Menu } from "./chrome";

/** Every moment in the video, in frames at 30 fps. */
const BEAT = {
  hookIn: 12,
  hookOut: 100,

  armHomePod: 122,
  armOffice: 168,
  armSonos: 212,
  clickCapIn: 108,
  clickCapOut: 252,

  dragStart: 276,
  dragEnd: 330,
  levelCapIn: 262,
  levelCapOut: 348,

  plusClick: 382,
  plusMenuIn: 384,
  plusMenuPick: 424,
  plusMenuOut: 434,
  saveCapIn: 362,
  saveCapOut: 500,

  cutOut: 510,
  cutIn: 538,
  laterCapIn: 512,
  laterCapOut: 552,

  destClick: 580,
  destMenuIn: 582,
  destMenuPick: 630,
  destMenuOut: 640,
  recall: 642,
  recallCapIn: 562,
  recallCapOut: 790,

  outroIn: 800,
  end: 900,
} as const;

export const SCENES_DURATION = BEAT.end;

/** Panel geometry the cursor and menus are aimed at, in points. */
const AT = {
  homePodName: [140, 257] as const,
  officeName: [140, 341] as const,
  sonosName: [140, 383] as const,
  homePodKnob: [268, 257] as const,
  homePodKnobEnd: [280, 257] as const,
  plus: [57, 421] as const,
  plusMenuItem: [92, 450] as const,
  destination: [436, 61] as const,
  destMenuScene: [400, 116] as const,
};

const ease = Easing.bezier(0.16, 1, 0.3, 1);

/** 0 before `at`, easing to 1 over `len` frames. */
const ramp = (frame: number, at: number, len: number) =>
  interpolate(frame, [at, at + len], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: ease,
  });

/** A value that rises, holds, then falls — for captions and overlays. */
const pulse = (frame: number, inAt: number, outAt: number, len = 12) =>
  interpolate(
    frame,
    [inAt, inAt + len, outAt, outAt + len],
    [0, 1, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease },
  );

export const ScenesVideo: React.FC = () => {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();

  // A speaker is live from the frame it is clicked until the time-cut, then
  // again from the moment the scene is recalled.
  const armed = (at: number) =>
    Math.max(
      ramp(frame, at, 14) * (1 - ramp(frame, BEAT.cutOut, 10)),
      ramp(frame, BEAT.recall, 16),
    );

  const homePodVolume = interpolate(
    frame,
    [BEAT.dragStart, BEAT.dragEnd],
    [25, 45],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease },
  );

  const devices: DeviceModel[] = [
    {
      id: "mac",
      name: "MacBook Pro Speakers",
      icon: "laptop",
      live: 0,
      volume: 65,
      meter: 0.2,
    },
    {
      id: "homepod",
      name: "Bedroom HomePod",
      icon: "homepod",
      live: armed(BEAT.armHomePod),
      volume: homePodVolume,
      meter: 0.62,
    },
    {
      id: "tv",
      name: "Living Room TV",
      icon: "appletv",
      live: 0,
      volume: 60,
      meter: 0.2,
    },
    {
      id: "office",
      name: "Office",
      icon: "speaker",
      live: armed(BEAT.armOffice),
      volume: 50,
      meter: 0.55,
    },
    {
      id: "sonos",
      name: "Sonos Move",
      icon: "speaker",
      live: armed(BEAT.armSonos),
      volume: 40,
      meter: 0.48,
    },
  ];

  const model: MixerModel = {
    destination:
      frame >= BEAT.recall ? "→ Whole house" : "Selected Speakers",
    mainVolume: 100,
    devices,
    airplayFrom: 1,
    hint: "Click a speaker's name to play your audio on it.",
    hintOpacity: 1 - ramp(frame, BEAT.armHomePod - 12, 14),
  };

  const panel = layout(model);

  // The camera is a push-in on the panel's own centre. It never pans: at this
  // scale the panel already fills the frame's width, so any sideways move
  // would slice a column off the edge.
  const scale = interpolate(
    frame,
    [0, 100, 250, 276, 348, 380, 500, 560, 690, 800],
    [2.0, 2.1, 2.1, 2.1, 2.0, 2.06, 2.06, 2.1, 2.0, 2.0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease },
  );

  // Cursor path — straight interpolation between the points it visits.
  const cursorFrames = [
    0, 100, 118, 132, 164, 178, 208, 222, 268, 276, BEAT.dragEnd, 344,
    378, 388, 404, 432, 500, 556, 578, 606, 636, 700, BEAT.end,
  ];
  const cursorX = [
    330, 330, AT.homePodName[0], AT.homePodName[0], AT.officeName[0],
    AT.officeName[0], AT.sonosName[0], AT.sonosName[0], AT.homePodKnob[0],
    AT.homePodKnob[0], AT.homePodKnobEnd[0], AT.homePodKnobEnd[0], AT.plus[0],
    AT.plus[0], AT.plusMenuItem[0], AT.plusMenuItem[0], AT.plusMenuItem[0],
    AT.destination[0], AT.destination[0], AT.destMenuScene[0],
    AT.destMenuScene[0], 440, 440,
  ];
  const cursorY = [
    470, 470, AT.homePodName[1], AT.homePodName[1], AT.officeName[1],
    AT.officeName[1], AT.sonosName[1], AT.sonosName[1], AT.homePodKnob[1],
    AT.homePodKnob[1], AT.homePodKnobEnd[1], AT.homePodKnobEnd[1], AT.plus[1],
    AT.plus[1], AT.plusMenuItem[1], AT.plusMenuItem[1], AT.plusMenuItem[1],
    AT.destination[1], AT.destination[1], AT.destMenuScene[1],
    AT.destMenuScene[1], 190, 190,
  ];

  const clicks = [
    BEAT.armHomePod,
    BEAT.armOffice,
    BEAT.armSonos,
    BEAT.plusClick,
    BEAT.plusMenuPick,
    BEAT.destClick,
    BEAT.destMenuPick,
  ];
  const pressed = clicks.reduce(
    (acc, at) =>
      Math.max(
        acc,
        interpolate(frame, [at - 3, at, at + 5], [0, 1, 0], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
      ),
    0,
  );

  const plusMenu = pulse(frame, BEAT.plusMenuIn, BEAT.plusMenuOut, 5);
  const destMenu = pulse(frame, BEAT.destMenuIn, BEAT.destMenuOut, 5);

  // The time-cut: the frame dips to canvas black between saving and recalling.
  const dip = interpolate(
    frame,
    [BEAT.cutOut, BEAT.cutOut + 14, BEAT.cutIn, BEAT.cutIn + 14],
    [0, 1, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease },
  );

  const panelIn = interpolate(frame, [0, 26], [0, 1], {
    extrapolateRight: "clamp",
    easing: ease,
  });
  const outro = ramp(frame, BEAT.outroIn, 24);

  return (
    <AbsoluteFill style={{ backgroundColor: color.canvas }}>
      {/* A warm pool of light behind the panel, so the frame is not flat black. */}
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: 1050,
          width: 1500,
          height: 1100,
          marginLeft: -750,
          marginTop: -550,
          borderRadius: "50%",
          background: `radial-gradient(closest-side, ${color.gold}14, transparent)`,
          opacity: 1 - outro,
        }}
      />

      <Caption
        text="Play on every speaker at once."
        opacity={pulse(frame, BEAT.hookIn, BEAT.hookOut) * (1 - outro)}
        lift={interpolate(pulse(frame, BEAT.hookIn, BEAT.hookOut), [0, 1], [18, 0])}
      />
      <Caption
        text="Click a name. It plays there."
        opacity={pulse(frame, BEAT.clickCapIn, BEAT.clickCapOut)}
        lift={0}
      />
      <Caption
        text="Every speaker keeps its own level."
        opacity={pulse(frame, BEAT.levelCapIn, BEAT.levelCapOut)}
        lift={0}
      />
      <Caption
        text="Save the set as a scene."
        accent="Name it in the Scenes window."
        opacity={pulse(frame, BEAT.saveCapIn, BEAT.saveCapOut)}
        lift={0}
      />
      <Caption
        text="Tomorrow morning."
        opacity={pulse(frame, BEAT.laterCapIn, BEAT.laterCapOut, 8)}
        lift={0}
      />
      <Caption
        text="One click. Everything’s back."
        accent="At the levels you left it."
        opacity={pulse(frame, BEAT.recallCapIn, BEAT.recallCapOut)}
        lift={0}
      />

      {/* The stage: the panel and everything drawn in its coordinate space. */}
      <div
        style={{
          position: "absolute",
          left: 0,
          top: 640,
          width,
          height: 1180,
          overflow: "hidden",
          opacity: (1 - dip) * (1 - outro),
        }}
      >
        <div
          style={{
            position: "absolute",
            left: (width - PANEL_WIDTH) / 2,
            top: (1180 - panel.height) / 2,
            width: PANEL_WIDTH,
            height: panel.height,
            scale: scale,
            translate: `0px ${interpolate(panelIn, [0, 1], [-70, 0])}px`,
            opacity: panelIn,
          }}
        >
          <Mixer model={model} />

          {clicks.map((at) => {
            const t = interpolate(frame, [at, at + 18], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            });
            if (t <= 0 || t >= 1) return null;
            const i = cursorFrames.findIndex((f) => f > at);
            return (
              <ClickRing
                key={at}
                x={cursorX[Math.max(0, i - 1)]}
                y={cursorY[Math.max(0, i - 1)]}
                t={t}
              />
            );
          })}

          <Menu
            x={48}
            y={436}
            width={250}
            reveal={plusMenu}
            highlight={frame >= BEAT.plusMenuIn + 14 ? 0 : -1}
            entries={[
              { title: "Save Selected Speakers as scene" },
              { title: "Pair a Bluetooth speaker…" },
            ]}
          />

          <Menu
            x={348}
            y={44}
            width={150}
            reveal={destMenu}
            highlight={frame >= BEAT.destMenuIn + 16 ? 3 : -1}
            entries={[
              { title: "Destination", header: true },
              { title: "Selected Speakers", checked: frame < BEAT.destMenuPick },
              { title: "Scenes", header: true },
              { title: "Whole house", checked: frame >= BEAT.destMenuPick },
            ]}
          />

          <Cursor
            x={interpolate(frame, cursorFrames, cursorX, {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: ease,
            })}
            y={interpolate(frame, cursorFrames, cursorY, {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: ease,
            })}
            press={pressed}
          />
        </div>
      </div>

      {/* Outro */}
      <AbsoluteFill
        style={{
          alignItems: "center",
          justifyContent: "center",
          opacity: outro,
          fontFamily: font.ui,
        }}
      >
        <div
          style={{
            fontSize: 132,
            fontWeight: 600,
            letterSpacing: "-0.03em",
            color: "#F7F6F4",
          }}
        >
          Audiout
        </div>
        <div
          style={{
            marginTop: 26,
            fontSize: 44,
            fontWeight: 400,
            color: color.goldText,
          }}
        >
          audiout.app
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
