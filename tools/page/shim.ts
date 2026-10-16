// Excalidraw fetches its fonts from a CDN.  The page carries them as data
// URIs in window.ESKETCH_FONTS, keyed by file name; rewrite every font URL
// and font fetch to those, so nothing leaves the machine.
const fonts: Record<string, string> = (window as any).ESKETCH_FONTS ?? {};
const local = (u: string) => {
  const name = u.split(/[?#]/)[0].split("/").pop() ?? "";
  return fonts[name];
};
const OrigFontFace = window.FontFace;
(window as any).FontFace = function (family: string, source: any, desc?: any) {
  if (typeof source === "string")
    source = source.replace(/url\((["']?)([^)"']+)\1\)/g, (m, _q, u) => (local(u) ? `url(${local(u)})` : m));
  return new OrigFontFace(family, source, desc);
};
(window as any).FontFace.prototype = OrigFontFace.prototype;
const origFetch = window.fetch.bind(window);
window.fetch = (input: any, init?: any) => {
  const u = typeof input === "string" ? input : input instanceof URL ? input.href : input?.url;
  const d = u && local(u);
  return d ? origFetch(d, init) : origFetch(input, init);
};
