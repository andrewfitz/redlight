export type DisplayStatus = {
  key: string;
  number: number;
  name: string;
  enabled: boolean;
  inverted: boolean;
};

export type LevelStatus = {
  set: number;
  target: number;
};

export type KelvinStatus = {
  set?: number | null;
  target?: number | null;
};

export type Status = {
  running: boolean;
  on?: boolean;
  displays?: DisplayStatus[];
  color?: LevelStatus;
  colorKelvin?: KelvinStatus;
  whitepoint?: LevelStatus;
  activePreset?: string;
  adaptive?: boolean;
  statusLine?: string;
  pausedUntil?: string;
  peeking?: boolean;
  fading?: boolean;
  activeApp?: {
    bundleID: string;
    name: string;
    rule: unknown;
  };
  [key: string]: unknown;
};

