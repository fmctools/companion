// Regenerates ios/WireKit/Tests/WireKitTests/face-gate-vectors.json from the site's own assertFlashable, so both
// apps refuse what fmc.tools refuses when a file can't be parsed or measured.
//   FMC_FRONTEND=~/Developer/pet/fcm-group/fmc_frontend bun tools/face-gate-vectors.ts > ios/WireKit/Tests/WireKitTests/face-gate-vectors.json
const root = process.env.FMC_FRONTEND ?? `${process.env.HOME}/Developer/pet/fcm-group/fmc_frontend`;
const { buildBin, assertFlashable } = await import(`${root}/src/lib/modules/editor/core/format/bin.ts`);

const toHex = (d: Uint8Array) => Buffer.from(d).toString("hex");
const meta = "00000000000000000000000000ff";
const res = (cf: number) => ({ cf, w: 4, h: 4, data: new Uint8Array([1, 2, 3, 4]) });
const shown = (i: number) => ({ tag: 0x30, subs: [{ tag: 0x01, x: 0, y: 0, meta, refType: 0x61, images: [i] }] });
const tail = (hex: string) => ({ tag: 0x30, subs: [{ tag: 0x01, x: 0, y: 0, meta, tail: hex }] });
const preview = { tag: 0x28, subs: [{ tag: 0x08, prefix: "0102030405", refType: 0x61, images: [0] }] };
const face = (subs: object[], cf = 4, previewCf = 4) =>
  buildBin({ name: "Gate", screens: [{ tag: 0x21, subs: [preview, ...subs] }], resources: [res(previewCf), res(cf)] });

const badFooter = face([shown(1)]);
badFooter[badFooter.length - 36] ^= 1;

const faces: [string, Uint8Array][] = [
  ["measured", face([shown(1), { tag: 0x40, hex: "0a" }])],
  ["preview_not_counted", face([shown(1)], 4, 6)],
  ["no_image_tail", face([shown(1), tail("0000")])],
  ["bad_footer", badFooter],
  ["unknown_format", face([shown(1)], 6)],
  ["dangling_reference", face([shown(1), tail("010100ffffff7f")])],
  ["opaque_screen", buildBin({ name: "Gate", screens: [{ tag: 0x21, hex: "30ffff" }], resources: [res(4)] })],
  ["opaque_container", face([{ tag: 0x68, hex: "30ffff" }])],
  ["short_struct", face([{ tag: 0x30, subs: [{ tag: 0x01, hex: "0a0b0c0d" }] }])],
];
const refuse = (bin: Uint8Array, device: string | null) => {
  try {
    assertFlashable(bin, device);
    return false;
  } catch {
    return true;
  }
};

console.log(JSON.stringify({
  faces: faces.map(([name, bin]) => ({
    name, hex: toHex(bin), refuse: { other: refuse(bin, null), watch_3_pro: refuse(bin, "watch_3_pro") },
  })),
}, null, 1));
