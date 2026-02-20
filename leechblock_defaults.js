/* LeechBlock NG default blocking configuration.
 *
 * Loaded by background.js via importScripts().
 * On first run (no sites configured), these defaults are seeded into
 * chrome.storage.local so the extension starts pre-configured.
 *
 * Mirrors the domains blocked in linux_configuration/hosts/install.sh.
 * With matchSubdomains=true, listing "youtube.com" automatically covers
 * www.youtube.com, m.youtube.com, etc.
 *
 * Maintained by install_leechblock.sh — edit THIS file then re-run the
 * installer to push changes into the extension.
 */

// eslint-disable-next-line no-unused-vars
const LEECHBLOCK_DEFAULTS = {

  // ── General options ────────────────────────────────────────────────
  numSets: "6",
  matchSubdomains: true,

  // ── Set 1 — YouTube & alternative front-ends ───────────────────────
  setName1: "YouTube",
  sites1: [
    // Core YouTube
    "youtube.com",
    "youtu.be",
    "youtube-nocookie.com",
    "youtubei.googleapis.com",
    "youtube.googleapis.com",
    "yt3.ggpht.com",
    "ytimg.com",
    "googlevideo.com",
    // Invidious instances
    "invidious.io",
    "invidio.us",
    "vid.puffyan.us",
    "yewtu.be",
    "invidious.kavin.rocks",
    "inv.riverside.rocks",
    "invidious.namazso.eu",
    "invidious.nerdvpn.de",
    "invidious.projectsegfau.lt",
    "invidious.slipfox.xyz",
    "invidious.privacydev.net",
    "invidious.perennialte.ch",
    "invidious.protokoll-11.de",
    "invidious.einfachzocken.eu",
    "invidious.fdn.fr",
    "inv.in.projectsegfau.lt",
    "invidious.tiekoetter.com",
    "invidious.lunar.icu",
    "iv.ggtyler.dev",
    "iv.melmac.space",
    "invidious.incogniweb.net",
    "invidious.drgns.space",
    "invidious.io.lol",
    "inv.n8pjl.ca",
    "inv.zzls.xyz",
    "inv.tux.pizza",
    // Piped instances
    "piped.video",
    "piped.kavin.rocks",
    "piped.mha.fi",
    "piped.mint.lgbt",
    "piped.projectsegfau.lt",
    "piped.privacydev.net",
    "piped.smnz.de",
    "piped.adminforge.de",
    "watch.whatever.social",
    "piped.lunar.icu",
    // Other alternative clients / front-ends
    "viewtube.io",
    "freetube.io",
    "tubo.media",
    "materialious.nadeko.net",
    "clipious.org",
    "newpipe.net",
    "newpipe.schabi.org",
    "grayjay.app",
    "libretube.dev",
    "hyperion.deishelon.com",
  ].join(" "),
  times1: "0000-2400",
  days1: [true, true, true, true, true, true, true],

  // ── Set 2 — Food delivery services ─────────────────────────────────
  setName2: "Food Delivery",
  sites2: [
    // Polish services
    "pyszne.pl",
    "glovo.com",
    "glovoapp.com",
    "bolt.eu",
    "woltwojta.pl",
    "wolt.com",
    "jush.pl",
    "delio.pl",
    "delio.com",
    "delio.com.pl",
    "lisek.app",
    "stava.app",
    "biedronka.pl",
    "barbora.pl",
    "frisco.pl",
    "swiatkwiatow.pl",
    "szama.pl",
    "auchandirect.pl",
    // International services
    "ubereats.com",
    "uber.com",
    "deliveroo.com",
    "deliveroo.co.uk",
    "foodpanda.com",
    "grubhub.com",
    "doordash.com",
    "justeat.com",
    "justeat.co.uk",
    "postmates.com",
    "seamless.com",
    "menulog.com.au",
    "delivery.com",
    "getir.com",
    "flink.com",
    "gorillas.io",
    "gopuff.com",
    "instacart.com",
    "takeaway.com",
  ].join(" "),
  times2: "0000-2400",
  days2: [true, true, true, true, true, true, true],

  // ── Set 3 — Fast food chain websites ───────────────────────────────
  setName3: "Fast Food",
  sites3: [
    "mcdonalds.com",
    "mcdonalds.pl",
    "kfc.com",
    "kfc.pl",
    "burgerking.com",
    "burgerking.pl",
    "pizzahut.com",
    "pizzahut.pl",
    "dominos.com",
    "dominos.pl",
    "subway.com",
    "subway.pl",
  ].join(" "),
  times3: "0000-2400",
  days3: [true, true, true, true, true, true, true],
};
