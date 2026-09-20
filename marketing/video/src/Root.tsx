import "./index.css";
import { Composition } from "remotion";
import { SCENES_DURATION, ScenesVideo } from "./ScenesVideo";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="Scenes"
        component={ScenesVideo}
        durationInFrames={SCENES_DURATION}
        fps={30}
        width={1080}
        height={1920}
      />
    </>
  );
};
