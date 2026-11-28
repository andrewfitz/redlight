import assert from "node:assert/strict";
import test from "node:test";
import { colorTempText, dialColorText, renderKey, setColorUnit } from "../.test-build/actions/action-support.js";

test("an out-of-range Kelvin target uses the target percentage", () => {
  const status = { running: true, color: { set: 55, target: 2 }, colorKelvin: { set: 4000 } };
  assert.equal(colorTempText(status, "kelvin"), "2%");
  status.colorKelvin.target = 3550;
  assert.equal(colorTempText(status), "2%");
  assert.equal(colorTempText(status, "kelvin"), "3550K");
});

test("an offline key clears the native title and shows no fabricated levels", () => {
  let title, image;
  renderKey({
    setTitle: async (value) => { title = value; },
    setImage: async (value) => { image = value; },
  }, { running: false });
  assert.equal(title, "");
  const svg = Buffer.from(image.split(",")[1], "base64").toString();
  assert.match(svg, />Offline</);
  assert.match(svg, />W --</);
  assert.doesNotMatch(svg, /100%/);
});

test("units follow each deck slot independently and reset when its settings are cleared", () => {
  const status = { running: true, color: { target: 47 }, colorKelvin: { target: 3250 } };
  setColorUnit("dial", "kelvin");
  assert.equal(dialColorText("dial", status), "3250K");
  assert.equal(dialColorText("key", status), "47%");
  setColorUnit("dial");
  assert.equal(dialColorText("dial", status), "47%");
});
