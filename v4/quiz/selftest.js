// OVERRIDE v3 // generator self-test (run: cscript //nologo selftest.js)
// Loads core.js into cscript's JScript engine (same family as the HTA engine) and
// hammers every subject x difficulty: structural invariants, normalization idempotency,
// and independent re-computation of the answer where the question text allows it.

function readUtf8(path) {
  var st = new ActiveXObject("ADODB.Stream");
  st.Type = 2; st.Charset = "utf-8"; st.Open(); st.LoadFromFile(path);
  var s = st.ReadText(); st.Close(); return s;
}
var fso = new ActiveXObject("Scripting.FileSystemObject");
var here = fso.GetParentFolderName(WScript.ScriptFullName);
eval(readUtf8(here + "\\core.js"));

var C = OVERRIDE_CORE;
var DIFFS = ["easy", "medium", "hard"];
var fails = 0, total = 0;

function fail(msg, o) {
  fails++;
  WScript.Echo("FAIL: " + msg + (o ? ("   q=[" + o.q + "] ans=[" + o.ans.join(";") + "]") : ""));
}
function nums(s) {  // all integers in the question text, in order
  var m = String(s).match(/-?\d+/g) || [], out = [], i;
  for (i = 0; i < m.length; i++) out.push(parseInt(m[i], 10));
  return out;
}
function hasAns(o, v) { return C.isHit(o, "" + v); }

/* semantic re-verification per subject (where the question text identifies the math) */
function verify(cat, diff, o) {
  var n = nums(o.q), i, ok;
  if (cat === "arithmetic") {
    if (n.length < 2) return fail("arith: <2 numbers", o);
    if (!(hasAns(o, n[0] + n[1]) || hasAns(o, n[0] - n[1]) || hasAns(o, n[0] * n[1])))
      return fail("arith: answer matches no operation", o);
  }
  else if (cat === "equations") {
    ok = false;
    // NOTE: cscript parses THIS file as ANSI, so unicode comparisons must use fromCharCode
    if (o.q.indexOf(String.fromCharCode(0xB2)) >= 0) ok = hasAns(o, Math.sqrt(n[0])); // x²=k (x>0); nums also catches the 0 in "(x > 0)"
    else if (n.length === 2) ok = hasAns(o, n[1] - n[0]) || hasAns(o, n[1] + n[0]);   // x+a=b | x-a=b
    else if (n.length === 3) ok = ((n[2] - n[1]) % n[0] === 0) && hasAns(o, (n[2] - n[1]) / n[0]); // ax+b=c
    else if (n.length === 4) ok = hasAns(o, (n[3] - n[1]) / (n[0] - n[2]));           // ax+b=cx+d
    if (!ok) return fail("equation: recomputed solution rejected", o);
  }
  else if (cat === "percentages") {
    ok = false;
    if (o.q.indexOf("of what") >= 0) ok = hasAns(o, n[1] === 0 ? 0 : n[0] * 100 / n[1]);
    else if (o.q.indexOf("increased") >= 0) ok = hasAns(o, n[0] + n[0] * n[1] / 100);
    else ok = hasAns(o, n[0] * n[1] / 100);
    if (!ok) return fail("percent: recomputed value rejected", o);
  }
  else if (cat === "powers") {
    ok = false;
    if (o.q.indexOf(String.fromCharCode(0x221A)) >= 0) ok = hasAns(o, Math.sqrt(n[0]));     // √
    else if (o.q.indexOf("2^") >= 0) ok = hasAns(o, Math.pow(2, n[n.length - 1]));
    else if (o.q.indexOf(String.fromCharCode(0xB3)) >= 0) ok = hasAns(o, n[0] * n[0] * n[0]); // ³
    else ok = hasAns(o, n[0] * n[0]);                                                         // ²
    if (!ok) return fail("power: recomputed value rejected", o);
  }
  else if (cat === "sequences") {
    if (n.length !== 4) return fail("sequence: expected 4 shown terms", o);
    var d1 = n[1] - n[0], d2 = n[2] - n[1], d3 = n[3] - n[2];
    ok = false;
    if (d1 === d2 && d2 === d3) ok = hasAns(o, n[3] + d1);                            // arithmetic
    else if (n[0] !== 0 && n[1] % n[0] === 0 && n[1] / n[0] > 1 && n[2] === n[1] * (n[1] / n[0]) && n[3] === n[2] * (n[1] / n[0])) ok = hasAns(o, n[3] * (n[1] / n[0])); // geometric (all 3 ratios)
    else ok = hasAns(o, n[3] + d3 + (d3 - d2));                                       // constant 2nd difference
    if (!ok) return fail("sequence: recomputed next term rejected", o);
  }
  else if (cat === "binary") {
    ok = false;
    if (o.q.indexOf("hex") >= 0) { var m = o.q.match(/0x([0-9A-F]+)/); ok = m && hasAns(o, parseInt(m[1], 16)); }
    else if (o.q.indexOf("binary ") === 0) { var mb = o.q.match(/binary (\d+)/); ok = mb && hasAns(o, parseInt(mb[1], 2)); }
    else { var md = o.q.match(/decimal (\d+)/), bin = "", x; if (md) { x = parseInt(md[1], 10); while (x > 0) { bin = (x % 2) + bin; x = Math.floor(x / 2); } ok = hasAns(o, bin); } }
    if (!ok) return fail("binary: recomputed conversion rejected", o);
  }
  else if (cat === "vectors" && o.q.indexOf("dot") >= 0) {
    if (!hasAns(o, n[0] * n[2] + n[1] * n[3])) return fail("vector: dot product mismatch", o);
  }
  else if (cat === "matrices" && o.q.indexOf("trace") === 0) {
    if (!hasAns(o, n[0] + n[3])) return fail("matrix: trace mismatch", o);
  }
  else if (cat === "matrices" && o.q.indexOf("det") === 0) {
    if (!hasAns(o, n[0] * n[3] - n[1] * n[2])) return fail("matrix: det mismatch", o);
  }
}

var ITER = 400;
for (var ci = 0; ci < C.CAT_KEYS.length; ci++) {
  var cat = C.CAT_KEYS[ci];
  for (var di = 0; di < DIFFS.length; di++) {
    var diff = DIFFS[di];
    for (var k = 0; k < ITER; k++) {
      total++;
      var o = C.genOne(cat, diff);
      if (!o || !o.q || String(o.q).length < 2) { fail(cat + "/" + diff + ": empty question", o); continue; }
      if (!o.ans || o.ans.length < 1) { fail(cat + "/" + diff + ": no answers", o); continue; }
      var bad = false;
      for (var ai = 0; ai < o.ans.length; ai++) {
        if (typeof o.ans[ai] !== "string" || o.ans[ai] === "") { fail(cat + "/" + diff + ": empty answer entry", o); bad = true; break; }
      }
      if (bad) continue;
      if (o.type !== "math" && o.type !== "vec" && o.type !== "text") { fail(cat + "/" + diff + ": bad type " + o.type, o); continue; }
      if (!o.cat) { fail(cat + "/" + diff + ": missing cat label", o); continue; }
      // normalization idempotency: feeding the canonical answer back must pass
      if (!C.isHit(o, o.ans[0])) { fail(cat + "/" + diff + ": canonical answer does not pass its own check", o); continue; }
      // a clearly-wrong answer must NOT pass
      if (C.isHit(o, "zz9_no")) { fail(cat + "/" + diff + ": garbage answer accepted", o); continue; }
      verify(cat, diff, o);
    }
  }
}

// narrator + prank pools sanity
if (C.LINES.victoryQuote.indexOf("champion") < 0) fail("victory quote lost!");
if (C.LINES.nag.length < 15) fail("nag pool shrank");
if (C.LINES.wrong.length < 10) fail("wrong pool shrank");
if (C.ERRS.length < 15) fail("prank pool shrank");

WScript.Echo((fails === 0 ? "ALL PASS" : fails + " FAILURES") + "  (" + total + " questions generated across " + C.CAT_KEYS.length + " subjects x 3 difficulties)");
WScript.Quit(fails === 0 ? 0 : 1);
