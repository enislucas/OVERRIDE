/* OVERRIDE v3 // shared quiz core
   ES3/ES5-only JavaScript: runs identically in mshta (IE11 engine, Windows),
   modern browsers (macOS/Linux kiosk mode) and cscript (selftest harness).
   No arrow functions, no let/const, no template literals, no Array extras.

   OVERRIDE_CORE = pure logic (generators, normalizers, narrator text). No DOM.
   OVERRIDE_UI   = the interactive quiz screen. Needs an `env` adapter from the shell:
     env.label        string   alarm label
     env.numQuestions int
     env.difficulty   "easy"|"medium"|"hard"
     env.cats         array of category keys
     env.matrixRain   bool     opt-in heavy ambient (off = lite, ~0 CPU)
     env.deadlineMs   number   epoch ms when the ring gives up (0 = unknown)
     env.speak(text)           narrator voice (SAPI / speechSynthesis); may no-op
     env.unlock()              report SOLVED to the ring engine (file or beacon)
     env.engineGone()          -> bool, true when the ring engine stopped
     env.closeWin()            close this window (may no-op in browsers)
*/

var OVERRIDE_CORE = (function () {

  /* ---------------- helpers ---------------- */
  function rnd(lo, hi) { return Math.floor(Math.random() * (hi - lo + 1)) + lo; }
  function pick(arr) { return arr[rnd(0, arr.length - 1)]; }
  function trim(s) { return String(s).replace(/^\s+|\s+$/g, ""); }

  function deaccent(s) {
    var o = "", i, cc, ch;
    for (i = 0; i < s.length; i++) {
      cc = s.charCodeAt(i); ch = s.charAt(i);
      if (cc >= 0x00e0 && cc <= 0x00e5) o += "a";
      else if (cc >= 0x00e8 && cc <= 0x00eb) o += "e";
      else if (cc >= 0x00ec && cc <= 0x00ef) o += "i";
      else if (cc >= 0x00f2 && cc <= 0x00f6) o += "o";
      else if (cc >= 0x00f9 && cc <= 0x00fc) o += "u";
      else if (cc === 0x00e7) o += "c";
      else if (cc === 0x00f1) o += "n";
      else o += ch;
    }
    return o;
  }
  /* math answers: lowercase, strip spaces, unify minus signs, drop multiply dots,
     superscripts -> ^n  (forgiving input conventions, same as v1/v2) */
  function normMath(s) {
    s = String(s).toLowerCase().replace(/\s+/g, "");
    var o = "", i, cc, ch;
    for (i = 0; i < s.length; i++) {
      cc = s.charCodeAt(i); ch = s.charAt(i);
      if (cc === 0x2212 || cc === 0x2013 || cc === 0x2014) o += "-";
      else if (cc === 0x00d7 || cc === 0x00b7 || ch === "*") { /* drop */ }
      else if (cc === 0x00b2) o += "^2";
      else if (cc === 0x00b3) o += "^3";
      else o += ch;
    }
    return o;
  }
  function normVec(s) { return normMath(s).replace(/[()\[\]]/g, ""); }
  function normText(s) {
    return trim(deaccent(String(s).toLowerCase())).replace(/\s+/g, " ").replace(/\./g, "");
  }
  function normFor(o, val) {
    if (o.type === "text") return normText(val);
    if (o.type === "vec") return normVec(val);
    return normMath(val);
  }
  function isHit(o, val) {
    var u = normFor(o, val), j;
    if (u === "") return false;
    for (j = 0; j < o.ans.length; j++) { if (u === o.ans[j]) return true; }
    return false;
  }

  /* polynomial display / join (derivatives & integrals) */
  function fmtPow(c, p) {
    if (p === 0) return "" + c;
    if (p === 1) return (c === 1 ? "x" : c + "x");
    return (c === 1 ? "" : "" + c) + "x^" + p;
  }
  function joinTerms(ts) {
    var a = [], i, out = "", c, p, t;
    for (i = 0; i < ts.length; i++) { if (ts[i].c !== 0) a.push(ts[i]); }
    a.sort(function (x, y) { return y.p - x.p; });
    if (a.length === 0) return "0";
    for (i = 0; i < a.length; i++) {
      c = a[i].c; p = a[i].p; t = fmtPow(Math.abs(c), p);
      out += (i === 0 ? (c < 0 ? "-" : "") : (c < 0 ? "-" : "+")) + t;
    }
    return out;
  }
  function dispTerm(c, p) {
    if (p === 0) return "" + c;
    if (p === 1) return c + "x";
    return c + "x^" + p;
  }
  function dispPoly(ts) {
    var out = "", i, c, p, t;
    for (i = 0; i < ts.length; i++) {
      c = ts[i].c; p = ts[i].p; t = dispTerm(Math.abs(c), p);
      out += (i === 0 ? (c < 0 ? "-" : "") : (c < 0 ? " - " : " + ")) + t;
    }
    return out;
  }

  var HINT_MATH = "number / expression, e.g. 12x^3-10x+2 (powers: x^2, multiply: 2x)";
  var HINT_VEC  = "vector (4,7) or 4,7  |  matrix row by row: 1,2,3,4";
  var HINT_TEXT = "just the word (capitalisation / accents forgiven)";

  /* ---------------- generators (one per subject) ---------------- */

  function genArith(d) {
    var t = rnd(0, 2), a, b, txt, ans;
    if (d === "easy") {
      if (t === 0) { a = rnd(1, 9); b = rnd(1, 9); txt = a + " + " + b; ans = a + b; }
      else if (t === 1) { a = rnd(10, 18); b = rnd(1, 9); txt = a + " − " + b; ans = a - b; }
      else { a = rnd(2, 5); b = rnd(2, 5); txt = a + " × " + b; ans = a * b; }
    } else if (d === "hard") {
      if (t === 0) { a = rnd(23, 89); b = rnd(23, 89); txt = a + " + " + b; ans = a + b; }
      else if (t === 1) { a = rnd(40, 99); b = rnd(11, 39); txt = a + " − " + b; ans = a - b; }
      else { a = rnd(6, 15); b = rnd(3, 12); txt = a + " × " + b; ans = a * b; }
    } else {
      if (t === 0) { a = rnd(8, 29); b = rnd(8, 29); txt = a + " + " + b; ans = a + b; }
      else if (t === 1) { a = rnd(15, 40); b = rnd(2, 14); txt = a + " − " + b; ans = a - b; }
      else { a = rnd(3, 7); b = rnd(3, 7); txt = a + " × " + b; ans = a * b; }
    }
    return { q: txt + " =", ans: [normMath("" + ans)], type: "math", cat: "ARITHMETIC", hint: HINT_MATH };
  }

  function genDeriv(d) {
    var t, n, k, a, m, b, c, orig, der, pickN, c2;
    if (d === "easy") {
      t = rnd(0, 1);
      if (t === 0) { n = rnd(2, 4); return { q: "d/dx ( x^" + n + " )", ans: [normMath(joinTerms([{ c: n, p: n - 1 }]))], type: "math", cat: "DERIVATIVE", hint: HINT_MATH }; }
      k = rnd(2, 9); return { q: "d/dx ( " + k + "x )", ans: [normMath("" + k)], type: "math", cat: "DERIVATIVE", hint: HINT_MATH };
    }
    if (d === "medium") {
      a = rnd(2, 5); m = rnd(2, 4); b = rnd(2, 6); k = rnd(1, m - 1);
      orig = [{ c: a, p: m }, { c: b, p: k }]; der = [{ c: a * m, p: m - 1 }, { c: b * k, p: k - 1 }];
      return { q: "d/dx ( " + dispPoly(orig) + " )", ans: [normMath(joinTerms(der))], type: "math", cat: "DERIVATIVE", hint: HINT_MATH };
    }
    pickN = rnd(0, 3);
    if (pickN === 0) {
      a = rnd(2, 4); b = rnd(2, 5); c = rnd(2, 6);
      orig = [{ c: a, p: 4 }, { c: -b, p: 2 }, { c: c, p: 1 }]; der = [{ c: 4 * a, p: 3 }, { c: -2 * b, p: 1 }, { c: c, p: 0 }];
      return { q: "d/dx ( " + dispPoly(orig) + " )", ans: [normMath(joinTerms(der))], type: "math", cat: "DERIVATIVE", hint: HINT_MATH };
    }
    if (pickN === 1) {
      k = rnd(2, 4);
      return { q: "d/dx ( e^(" + k + "x) )", ans: [normMath(k + "e^(" + k + "x)"), normMath(k + "e^" + k + "x")], type: "math", cat: "DERIVATIVE", hint: HINT_MATH };
    }
    if (pickN === 2) {
      a = rnd(2, 4);
      return { q: "d/dx ( ln(x) + " + a + "x^3 )", ans: [normMath("1/x+" + (3 * a) + "x^2")], type: "math", cat: "DERIVATIVE", hint: HINT_MATH };
    }
    c2 = rnd(2, 3);
    return { q: "d/dx ( sin(x) − " + c2 + "cos(x) )", ans: [normMath("cos(x)+" + c2 + "sin(x)"), normMath("cosx+" + c2 + "sinx")], type: "math", cat: "DERIVATIVE", hint: HINT_MATH };
  }

  function genVector(d) {
    var a, b, c, e, k, lo, hi;
    if (d === "hard") {
      a = rnd(1, 9); b = rnd(1, 9); c = rnd(1, 9); e = rnd(1, 9);
      return { q: "(" + a + "," + b + ") · (" + c + "," + e + ")   [dot product]", ans: [normMath("" + (a * c + b * e))], type: "math", cat: "VECTOR", hint: HINT_MATH };
    }
    if (d === "medium" && rnd(0, 1) === 0) {
      k = rnd(2, 5); a = rnd(1, 9); b = rnd(1, 9);
      return { q: k + " × (" + a + "," + b + ")", ans: [normVec("(" + (k * a) + "," + (k * b) + ")")], type: "vec", cat: "VECTOR", hint: HINT_VEC };
    }
    lo = (d === "medium") ? 5 : 1; hi = (d === "medium") ? 20 : 9;
    a = rnd(lo, hi); b = rnd(lo, hi); c = rnd(lo, hi); e = rnd(lo, hi);
    if (rnd(0, 1) === 0) return { q: "(" + a + "," + b + ") + (" + c + "," + e + ")", ans: [normVec("(" + (a + c) + "," + (b + e) + ")")], type: "vec", cat: "VECTOR", hint: HINT_VEC };
    return { q: "(" + (a + c) + "," + (b + e) + ") − (" + c + "," + e + ")", ans: [normVec("(" + a + "," + b + ")")], type: "vec", cat: "VECTOR", hint: HINT_VEC };
  }

  function genMatrix(d) {
    function M() { var lo = (d === "hard") ? -6 : 1, hi = 9; return [rnd(lo, hi), rnd(lo, hi), rnd(lo, hi), rnd(lo, hi)]; }
    var m = M(), x, r;
    if (d === "easy") return { q: "trace [[" + m[0] + "," + m[1] + "],[" + m[2] + "," + m[3] + "]]", ans: [normMath("" + (m[0] + m[3]))], type: "math", cat: "MATRIX", hint: HINT_MATH };
    if (d === "hard") {
      x = M(); r = [m[0] + x[0], m[1] + x[1], m[2] + x[2], m[3] + x[3]];
      return { q: "[[" + m[0] + "," + m[1] + "],[" + m[2] + "," + m[3] + "]] + [[" + x[0] + "," + x[1] + "],[" + x[2] + "," + x[3] + "]]", ans: [normVec(r[0] + "," + r[1] + "," + r[2] + "," + r[3])], type: "vec", cat: "MATRIX (add, row by row)", hint: HINT_VEC };
    }
    return { q: "det [[" + m[0] + "," + m[1] + "],[" + m[2] + "," + m[3] + "]]", ans: [normMath("" + (m[0] * m[3] - m[1] * m[2]))], type: "math", cat: "MATRIX", hint: HINT_MATH };
  }

  var CAP = {
    easy: [["France", ["paris"]], ["Japan", ["tokyo"]], ["Italy", ["rome"]], ["Spain", ["madrid"]], ["Germany", ["berlin"]], ["Egypt", ["cairo"]], ["Russia", ["moscow"]], ["China", ["beijing"]], ["Greece", ["athens"]], ["Portugal", ["lisbon"]], ["the United Kingdom", ["london"]], ["the USA", ["washington", "washington dc"]], ["Mexico", ["mexico city"]], ["South Korea", ["seoul"]], ["India", ["new delhi", "delhi"]]],
    medium: [["Canada", ["ottawa"]], ["Australia", ["canberra"]], ["Brazil", ["brasilia"]], ["Turkey", ["ankara"]], ["Switzerland", ["bern", "berne"]], ["the Netherlands", ["amsterdam"]], ["Sweden", ["stockholm"]], ["Norway", ["oslo"]], ["Poland", ["warsaw"]], ["Austria", ["vienna"]], ["Ireland", ["dublin"]], ["Finland", ["helsinki"]], ["Argentina", ["buenos aires"]], ["Czechia", ["prague"]], ["Hungary", ["budapest"]], ["Belgium", ["brussels"]], ["Denmark", ["copenhagen"]]],
    hard: [["Morocco", ["rabat"]], ["New Zealand", ["wellington"]], ["Nigeria", ["abuja"]], ["Vietnam", ["hanoi"]], ["Pakistan", ["islamabad"]], ["Saudi Arabia", ["riyadh"]], ["Ukraine", ["kyiv", "kiev"]], ["Indonesia", ["jakarta"]], ["the Philippines", ["manila"]], ["Chile", ["santiago"]], ["Colombia", ["bogota"]], ["Kazakhstan", ["astana", "nur-sultan"]], ["Ethiopia", ["addis ababa"]], ["Tanzania", ["dodoma"]], ["Bolivia", ["la paz", "sucre"]], ["Kenya", ["nairobi"]]]
  };
  function genCapital(d) {
    var arr = CAP[d] || CAP.easy, p = pick(arr), acc = [], i;
    for (i = 0; i < p[1].length; i++) acc.push(normText(p[1][i]));
    return { q: "Capital of " + p[0] + " ?", ans: acc, type: "text", cat: "GEOGRAPHY", hint: HINT_TEXT };
  }

  function genEquation(d) {
    var x, a, b, c, dd, k;
    if (d === "easy") {
      x = rnd(2, 9); a = rnd(2, 9);
      if (rnd(0, 1) === 0) return { q: "x + " + a + " = " + (x + a) + "      x = ?", ans: [normMath("" + x)], type: "math", cat: "EQUATION", hint: HINT_MATH };
      return { q: "x − " + a + " = " + x + "      x = ?", ans: [normMath("" + (x + a))], type: "math", cat: "EQUATION", hint: HINT_MATH };
    }
    if (d === "medium") {
      x = rnd(2, 9); a = rnd(2, 6); b = rnd(1, 9);
      return { q: a + "x + " + b + " = " + (a * x + b) + "      x = ?", ans: [normMath("" + x)], type: "math", cat: "EQUATION", hint: HINT_MATH };
    }
    if (rnd(0, 1) === 0) {
      x = rnd(2, 9); a = rnd(3, 7); c = rnd(1, a - 1); b = rnd(1, 9); dd = (a - c) * x + b;
      return { q: a + "x + " + b + " = " + c + "x + " + dd + "      x = ?", ans: [normMath("" + x)], type: "math", cat: "EQUATION", hint: HINT_MATH };
    }
    k = rnd(3, 12);
    return { q: "x² = " + (k * k) + "  (x > 0)      x = ?", ans: [normMath("" + k)], type: "math", cat: "EQUATION", hint: HINT_MATH };
  }

  function gcd(a, b) { while (b) { var t = a % b; a = b; b = t; } return a; }
  function genPercent(d) {
    /* questions are CONSTRUCTED so the result is always an exact integer */
    var p, a, n, b, x, den;
    if (d === "easy") {
      p = pick([10, 25, 50]); a = rnd(2, 12);
      n = (p === 10) ? a * 10 : (p === 25 ? a * 4 : a * 2);
      return { q: p + "% of " + n + " =", ans: [normMath("" + a)], type: "math", cat: "PERCENTAGES", hint: HINT_MATH };
    }
    if (d === "medium") {
      p = pick([5, 20, 25, 50, 75]); den = 100 / gcd(p, 100);
      n = rnd(2, 20) * den; a = n * p / 100;
      return { q: p + "% of " + n + " =", ans: [normMath("" + a)], type: "math", cat: "PERCENTAGES", hint: HINT_MATH };
    }
    if (rnd(0, 1) === 0) {
      p = pick([10, 20, 25, 50]); den = 100 / p;
      b = rnd(2, 25) * den; x = b / den;
      return { q: x + " is " + p + "% of what number?", ans: [normMath("" + b)], type: "math", cat: "PERCENTAGES", hint: HINT_MATH };
    }
    n = rnd(2, 20) * 10; p = pick([10, 20, 30, 50]);
    return { q: n + " increased by " + p + "% =", ans: [normMath("" + (n + n * p / 100))], type: "math", cat: "PERCENTAGES", hint: HINT_MATH };
  }

  function genPower(d) {
    var n;
    if (d === "easy") {
      n = rnd(2, 12);
      if (rnd(0, 1) === 0) return { q: n + "² =", ans: [normMath("" + n * n)], type: "math", cat: "POWERS & ROOTS", hint: HINT_MATH };
      return { q: "√" + (n * n) + " =", ans: [normMath("" + n)], type: "math", cat: "POWERS & ROOTS", hint: HINT_MATH };
    }
    if (d === "medium") {
      if (rnd(0, 1) === 0) { n = rnd(2, 6); return { q: n + "³ =", ans: [normMath("" + n * n * n)], type: "math", cat: "POWERS & ROOTS", hint: HINT_MATH }; }
      n = rnd(4, 8); return { q: "2^" + n + " =", ans: [normMath("" + Math.pow(2, n))], type: "math", cat: "POWERS & ROOTS", hint: HINT_MATH };
    }
    if (rnd(0, 1) === 0) { n = rnd(13, 25); return { q: "√" + (n * n) + " =", ans: [normMath("" + n)], type: "math", cat: "POWERS & ROOTS", hint: HINT_MATH }; }
    n = rnd(13, 20); return { q: n + "² =", ans: [normMath("" + n * n)], type: "math", cat: "POWERS & ROOTS", hint: HINT_MATH };
  }

  function genSequence(d) {
    var s, df, r, t, inc, a1, a2, a3, a4, a5;
    if (d === "easy") {
      s = rnd(1, 9); df = rnd(2, 9);
      return { q: s + ", " + (s + df) + ", " + (s + 2 * df) + ", " + (s + 3 * df) + ", ?", ans: [normMath("" + (s + 4 * df))], type: "math", cat: "SEQUENCE", hint: HINT_MATH };
    }
    if (d === "medium") {
      if (rnd(0, 1) === 0) {
        s = rnd(1, 4); r = pick([2, 3]); t = [s, s * r, s * r * r, s * r * r * r];
        return { q: t[0] + ", " + t[1] + ", " + t[2] + ", " + t[3] + ", ?", ans: [normMath("" + (t[3] * r))], type: "math", cat: "SEQUENCE", hint: HINT_MATH };
      }
      s = rnd(40, 90); df = rnd(3, 9);
      return { q: s + ", " + (s - df) + ", " + (s - 2 * df) + ", " + (s - 3 * df) + ", ?", ans: [normMath("" + (s - 4 * df))], type: "math", cat: "SEQUENCE", hint: HINT_MATH };
    }
    a1 = rnd(1, 6); df = rnd(2, 4); inc = rnd(1, 3);
    a2 = a1 + df; a3 = a2 + df + inc; a4 = a3 + df + 2 * inc; a5 = a4 + df + 3 * inc;
    return { q: a1 + ", " + a2 + ", " + a3 + ", " + a4 + ", ?", ans: [normMath("" + a5)], type: "math", cat: "SEQUENCE", hint: HINT_MATH };
  }

  function genIntegral(d) {
    var k, a, b, t1, t2, base;
    function withC(s) { return [normMath(s), normMath(s + "+c")]; }
    if (d === "easy") {
      k = rnd(2, 9);
      return { q: "∫ " + k + " dx =", ans: withC(k + "x"), type: "math", cat: "INTEGRAL", hint: HINT_MATH + "  (+C optional)" };
    }
    if (d === "medium") {
      if (rnd(0, 1) === 0) { a = pick([2, 4, 6, 8]); return { q: "∫ " + a + "x dx =", ans: withC((a / 2) + "x^2"), type: "math", cat: "INTEGRAL", hint: HINT_MATH + "  (+C optional)" }; }
      a = pick([3, 6, 9]); return { q: "∫ " + a + "x² dx =", ans: withC((a / 3) + "x^3"), type: "math", cat: "INTEGRAL", hint: HINT_MATH + "  (+C optional)" };
    }
    a = pick([2, 4, 6]); b = rnd(2, 9);
    t1 = (a / 2) + "x^2"; t2 = b + "x"; base = t1 + "+" + t2;
    return { q: "∫ ( " + a + "x + " + b + " ) dx =", ans: withC(base), type: "math", cat: "INTEGRAL", hint: HINT_MATH + "  (+C optional)" };
  }

  function genBinary(d) {
    var v, bits, i, hx;
    function toBin(n) { var s = "", x = n; if (x === 0) return "0"; while (x > 0) { s = (x % 2) + s; x = Math.floor(x / 2); } return s; }
    if (d === "easy") {
      v = rnd(2, 15); bits = toBin(v); while (bits.length < 4) bits = "0" + bits;
      return { q: "binary " + bits + "  →  decimal ?", ans: [normMath("" + v)], type: "math", cat: "BINARY / HEX", hint: HINT_MATH };
    }
    if (d === "medium") {
      v = rnd(5, 31);
      return { q: "decimal " + v + "  →  binary ?", ans: [normMath(toBin(v))], type: "math", cat: "BINARY / HEX", hint: "binary digits, e.g. 10110" };
    }
    v = rnd(16, 255); hx = v.toString(16).toUpperCase();
    return { q: "hex 0x" + hx + "  →  decimal ?", ans: [normMath("" + v)], type: "math", cat: "BINARY / HEX", hint: HINT_MATH };
  }

  var ELEM = {
    easy: [["H", ["hydrogen"]], ["O", ["oxygen"]], ["C", ["carbon"]], ["N", ["nitrogen"]], ["Fe", ["iron"]], ["Au", ["gold"]], ["Ag", ["silver"]], ["Na", ["sodium"]], ["He", ["helium"]], ["Ca", ["calcium"]]],
    medium: [["potassium", ["k"]], ["copper", ["cu"]], ["zinc", ["zn"]], ["magnesium", ["mg"]], ["silicon", ["si"]], ["chlorine", ["cl"]], ["neon", ["ne"]], ["aluminium", ["al"]], ["sulfur", ["s"]], ["lithium", ["li"]]],
    hard: [["Pb", ["lead"]], ["Sn", ["tin"]], ["Hg", ["mercury"]], ["W", ["tungsten", "wolfram"]], ["Sb", ["antimony"]], ["Mn", ["manganese"]], ["Cr", ["chromium"]], ["Pt", ["platinum"]], ["U", ["uranium"]], ["Ti", ["titanium"]]]
  };
  function genElement(d) {
    var arr = ELEM[d] || ELEM.easy, p = pick(arr), acc = [], i;
    for (i = 0; i < p[1].length; i++) acc.push(normText(p[1][i]));
    if (d === "medium") return { q: "Chemical symbol of " + p[0] + " ?", ans: acc, type: "text", cat: "CHEMISTRY", hint: "the symbol, e.g. Fe" };
    return { q: "Element with symbol  " + p[0] + "  ?", ans: acc, type: "text", cat: "CHEMISTRY", hint: HINT_TEXT };
  }

  /* registry: key -> generator. Keys are what config.json uses. */
  var GENS = {
    arithmetic: genArith, derivatives: genDeriv, vectors: genVector, matrices: genMatrix,
    capitals: genCapital, equations: genEquation, percentages: genPercent, powers: genPower,
    sequences: genSequence, integrals: genIntegral, binary: genBinary, elements: genElement
  };
  var CAT_KEYS = ["arithmetic", "derivatives", "vectors", "matrices", "capitals",
    "equations", "percentages", "powers", "sequences", "integrals", "binary", "elements"];

  function genOne(catKey, diff) {
    var g = GENS[catKey] || genArith;
    return g(diff === "easy" || diff === "hard" ? diff : "medium");
  }

  /* ---------------- narrator ---------------- */
  var LINES = {
    start: [
      "Wake up. Solve to disable the alarm.",
      "Good morning, subject. Identity verification required.",
      "Initiating wake protocol. Resistance is adorable.",
      "Rise and shine. The machine demands proof of consciousness.",
      "Your bed has been compromised. Evacuate immediately.",
      "This is not a drill. Actually, it is exactly a drill. Solve it.",
      "Attention. Horizontal mode has been deprecated.",
      "Boot sequence started. Human, verify you are not a vegetable."
    ],
    nag: [
      "Solve it. Wake up.",
      "Still horizontal? Pathetic.",
      "I can do this all morning.",
      "Your blanket will not save you.",
      "Recompute. Now.",
      "The questions are not going to solve themselves.",
      "Every second you wait, I get louder in spirit.",
      "Your future self is watching. They are not impressed.",
      "Sleep is a subscription you cannot afford right now.",
      "I have nowhere else to be. You, however, do.",
      "The snooze button does not exist. I made sure of it.",
      "Your pillow is lying to you.",
      "Day not seized detected. Deploying countermeasures.",
      "This alarm is powered by your regret.",
      "Math now. Existential dread later.",
      "You installed me. Think about that.",
      "The bed is lava. The bed has always been lava.",
      "Coffee is on the other side of this quiz.",
      "Statistically, you are already losing to everyone in a timezone ahead of you.",
      "I believe in you. Unfortunately for you."
    ],
    wrong: [
      "Wrong. Recompute.",
      "Incorrect. The bar was low. You went under it.",
      "Negative. Try using the awake part of your brain.",
      "Error: answer rejected. Like your excuses.",
      "That was a guess. I can tell.",
      "Denied. Even the calculator is embarrassed.",
      "Close. In the way that Mars is close to Earth.",
      "Nope. Blink twice and try again.",
      "Incorrect. Your diploma is watching.",
      "Failure logged. Your 9 AM self has been notified.",
      "Wrong again. This is going in the report.",
      "Access denied. Consciousness not detected."
    ],
    victoryQuote: "Alarm disabled. You beat the machine. Now go win the day, champion.",
    victoryPre: [
      "Access granted.",
      "Verification complete.",
      "Identity confirmed. Welcome back, human.",
      "Protocol satisfied."
    ]
  };

  /* ---------------- fake error pranks ---------------- */
  var ERRS = [
    ["FATAL_ERROR 0x57AKE", "Subject still detected in horizontal position. This incident has been reported to your 9 AM self."],
    ["CRITICAL FAULT", "Laziness.dll is consuming 100% of your remaining potential. Solve math to terminate process."],
    ["SECURITY ALERT", "Unauthorized snooze attempt from device BED-01. Deploying countermeasures..."],
    ["motivation.exe", "motivation.exe could not be located. Please reinstall by standing up."],
    ["INCOMING CALL", "Your future self has joined the call. They look... disappointed."],
    ["UPDATE REQUIRED", "Installing Discipline 2.0 — do not turn off your human. 3% complete. Estimated time: your whole life."],
    ["KERNEL PANIC (yours)", "consciousness.sys failed to load. Press any neuron to continue."],
    ["LOW RESOURCES", "Willpower at 4%. Connect to coffee source immediately."],
    ["DISK FULL", "Drive DREAMS:\\ is full. Delete excuses to free up space."],
    ["NETWORK ERROR", "Connection to bed lost. This is permanent. Do not attempt to reconnect."],
    ["LICENSE EXPIRED", "Your free trial of 'five more minutes' has ended. Purchase wakefulness to continue."],
    ["SYNC CONFLICT", "Your goals and your blanket have a merge conflict. Resolving in favor of goals."],
    ["DRIVER MISSING", "ambition.drv not found. Falling back to panic mode."],
    ["THERMAL WARNING", "Bed temperature optimal. That is the problem. Evacuate."],
    ["404", "Productivity not found. Did you mean: get up?"],
    ["PERMISSION DENIED", "sudo sleep 300 — user is not in the snoozers group. This incident will be reported."],
    ["STACK OVERFLOW", "Too many recursive 'just one more minute' calls. Core dumped onto floor. You are the core."],
    ["ANTIVIRUS", "Threat quarantined: comfort_zone.exe. Recommended action: leave it."]
  ];

  return {
    rnd: rnd, pick: pick, trim: trim,
    normMath: normMath, normVec: normVec, normText: normText, normFor: normFor, isHit: isHit,
    genOne: genOne, GENS: GENS, CAT_KEYS: CAT_KEYS,
    LINES: LINES, ERRS: ERRS
  };
})();

/* ===================== interactive quiz UI ===================== */
/* Only referenced from the HTA/HTML shells (never from cscript selftest). */
var OVERRIDE_UI = (function () {
  var C = OVERRIDE_CORE;
  var env = null, Q = null, idx = 0, N = 3, solved = 0, wrongs = 0;
  var lastSpoke = 0, revealTimer = null, started = null, finished = false;

  function el(id) { return document.getElementById(id); }

  function buildDom() {
    var i, dots = "";
    for (i = 0; i < N; i++) dots += '<span class="dot" id="dot' + i + '"></span>';
    var h =
      '<canvas id="rain"></canvas><div id="vignette"></div><div id="scan"></div>' +
      '<div id="stage"><div id="panel">' +
      '<div id="topbar"><span id="clock"></span><span class="brand">OVERRIDE // WAKE PROTOCOL &nbsp;[ ' + env.label + ' ]</span></div>' +
      '<div id="body"><div id="quiz">' +
      '<h1>IDENTITY VERIFICATION</h1>' +
      '<div class="sub">Answer each question to prove consciousness and disable the alarm.<span class="blink">_</span></div>' +
      '<div id="prog">' + dots + ' &nbsp; <span id="progtxt"></span></div>' +
      '<div class="cat" id="qcat"></div>' +
      '<div id="qtext"></div>' +
      '<div id="ansrow"><input id="ans" maxlength="40" autocomplete="off" /><button id="go">&gt; SUBMIT</button></div>' +
      '<div id="hint"></div><div id="msg">&nbsp;</div>' +
      '</div>' +
      '<div id="done"><h1>&#10003; ACCESS GRANTED</h1><div id="quote"></div><div id="stats"></div></div>' +
      '</div></div></div>' +
      '<div id="err"><div class="bar"><span id="errTitle">Script Error</span><span class="x" id="errX">x</span></div>' +
      '<div class="body"><div class="ico">&#9888;</div><div id="errMsg">An error has occurred.</div>' +
      '<table><tr><td>Line:</td><td id="errLine">404</td></tr><tr><td>Char:</td><td>3</td></tr><tr><td>Code:</td><td>0xDEADBED</td></tr></table>' +
      '<div class="foot"><button id="errOk">...fine</button><button id="errNo">make it stop</button></div></div></div>' +
      '<div id="ended">ALARM ENDED — you can close this window.</div>';
    document.body.innerHTML = h;
  }

  function speak(t) {
    var now = new Date().getTime();
    if (now - lastSpoke < 5000) return;  /* throttle so taunts never queue up */
    lastSpoke = now;
    try { env.speak(t); } catch (e) { }
  }

  function showErr() {
    var e = C.pick(C.ERRS);
    el('errTitle').innerHTML = e[0];
    el('errMsg').innerHTML = e[1];
    el('errLine').innerHTML = "" + C.rnd(100, 999);
    el('err').style.display = "block";
    try { el('ans').focus(); } catch (ex) { }
  }
  function hideErr() { el('err').style.display = "none"; try { el('ans').focus(); } catch (ex) { } }

  function newQuestion() {
    var cat = C.pick(env.cats);
    Q = C.genOne(cat, env.difficulty);
    el('qcat').innerHTML = Q.cat;
    el('hint').innerHTML = Q.hint || "";
    el('ans').value = ""; el('ans').className = "";
    revealText(Q.q);
    refreshProg();
    centerPanel();
    try { el('ans').focus(); } catch (e) { }
  }

  /* decrypt-style reveal: one short burst per question (~600ms), then idle */
  function revealText(txt) {
    var GL = "#$%/\\<>*+=0123456789ABCDEF", steps = 0, total = 14, t = el('qtext');
    if (revealTimer) { clearInterval(revealTimer); revealTimer = null; }
    revealTimer = setInterval(function () {
      steps++;
      var keep = Math.floor(txt.length * steps / total), s = txt.substring(0, keep), i;
      for (i = keep; i < txt.length; i++) {
        s += (txt.charAt(i) === " ") ? " " : GL.charAt(C.rnd(0, GL.length - 1));
      }
      t.innerHTML = s;
      if (steps >= total) { clearInterval(revealTimer); revealTimer = null; t.innerHTML = txt; }
    }, 42);
  }

  /* vertical centring in JS — mshta's IE11 engine ignores transform/flex and collapses
     injected table-cells, so CSS-only centring fails there (bug museum #16) */
  function centerPanel() {
    try {
      var p = el('panel'), ph = p.offsetHeight || 0;
      /* viewport height: docEl in standards mode, body in quirks; never the content height */
      var bh = document.documentElement.clientHeight || document.body.clientHeight || 0;
      if (ph < 50 || bh < 100) return;          /* layout not settled yet — next call fixes it */
      var m = Math.floor((bh - ph) / 2); if (m < 12) m = 12;
      /* relative offset, NOT margin-top: a top margin collapses through #stage and its
         visual effect becomes engine-dependent */
      p.style.position = "relative"; p.style.top = m + "px";
    } catch (e) { }
  }

  function refreshProg() {
    var i, d;
    for (i = 0; i < N; i++) {
      d = el('dot' + i); if (!d) continue;
      d.className = "dot" + (i < solved ? " on" : (i === solved ? " cur" : ""));
    }
    el('progtxt').innerHTML = "VERIFIED " + solved + " / " + N;
  }

  function shake() {
    var p = el('panel');
    p.className = "";
    setTimeout(function () { p.className = "shake"; }, 10);
    setTimeout(function () { p.className = ""; }, 460);
  }

  function check() {
    if (finished || !Q) return;
    var box = el('ans');
    if (C.isHit(Q, box.value)) {
      solved++;
      box.className = "ok";
      el('msg').innerHTML = '<span class="good">&gt; VERIFIED</span>';
      if (solved >= N) { victory(); return; }
      refreshProg();
      setTimeout(function () { el('msg').innerHTML = "&nbsp;"; newQuestion(); }, 420);
    } else {
      wrongs++;
      box.className = "bad";
      var taunt = C.pick(C.LINES.wrong);
      el('msg').innerHTML = '<span class="bad">&gt; ' + taunt + '</span>';
      speak(taunt);
      shake();
      if (C.rnd(0, 9) < 4) showErr();
      newQuestion();
    }
  }

  function victory() {
    if (finished) return;
    finished = true;
    /* unlock FIRST — the ring must stop even if the fancy ending breaks */
    try { env.unlock(); } catch (e) { }
    if (revealTimer) { clearInterval(revealTimer); revealTimer = null; }
    refreshProg();
    el('quiz').style.display = "none";
    el('done').style.display = "block";
    centerPanel();
    var quote = C.LINES.victoryQuote;
    el('quote').innerHTML = quote;
    var secs = Math.round(((new Date()).getTime() - started) / 1000);
    el('stats').innerHTML = "solved " + N + " question" + (N === 1 ? "" : "s") + " in " + secs + "s" +
      (wrongs > 0 ? (" &nbsp;|&nbsp; " + wrongs + " failed attempt" + (wrongs === 1 ? "" : "s") + " (we saw that)") : " &nbsp;|&nbsp; flawless");
    lastSpoke = 0;                                  /* never throttle the champion quote */
    speak(C.pick(C.LINES.victoryPre) + " " + quote);
    setTimeout(function () { try { env.closeWin(); } catch (e) { } }, 8000);
  }

  function tickClock() {
    if (!env.deadlineMs) return;
    var left = Math.floor((env.deadlineMs - (new Date()).getTime()) / 1000), m, s, c = el('clock');
    if (left < 0) left = 0;
    m = Math.floor(left / 60); s = left % 60;
    c.innerHTML = (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
    c.className = (left <= 30) ? "low" : "";
  }

  function watchEngine() {
    if (finished) return;
    try {
      if (env.engineGone()) {
        el('ended').style.display = "block";
        try { env.closeWin(); } catch (e) { }
      }
    } catch (e2) { }
  }

  function startRain() {
    var c = el('rain'), x, fs = 16, cols, drops = [], i,
      chars = "01234567890123456789ABCDEFXYZ<>/\\*-+=#%";
    c.width = document.body.clientWidth || 1024; c.height = document.body.clientHeight || 768;
    x = c.getContext('2d'); cols = Math.floor(c.width / fs);
    for (i = 0; i < cols; i++) drops[i] = Math.floor(Math.random() * (c.height / fs));
    setInterval(function () {
      x.fillStyle = "rgba(0,0,0,0.08)"; x.fillRect(0, 0, c.width, c.height);
      x.fillStyle = "#00ff66"; x.font = fs + "px monospace";
      for (var j = 0; j < drops.length; j++) {
        x.fillText(chars.charAt(Math.floor(Math.random() * chars.length)), j * fs, drops[j] * fs);
        if (drops[j] * fs > c.height && Math.random() > 0.975) drops[j] = 0;
        drops[j]++;
      }
    }, 90);
  }

  function init(envIn) {
    env = envIn;
    N = env.numQuestions; if (isNaN(N) || N < 1) N = 3; if (N > 6) N = 6;
    if (!env.cats || env.cats.length === 0) env.cats = ["arithmetic"];
    started = (new Date()).getTime();
    buildDom();
    el('go').onclick = check;
    el('errX').onclick = hideErr;
    el('errOk').onclick = hideErr;
    el('errNo').onclick = function () { hideErr(); el('msg').innerHTML = '<span class="bad">&gt; No.</span>'; };
    el('ans').onkeydown = function (ev) {
      ev = ev || window.event;
      var k = ev.keyCode || ev.which;
      if (k === 13) check();
    };
    if (env.matrixRain) { startRain(); }
    if (env.deadlineMs) { tickClock(); setInterval(tickClock, 1000); }
    setInterval(watchEngine, 1500);
    window.onresize = centerPanel;
    newQuestion();
    setTimeout(centerPanel, 60);     /* once more after first layout settles */
    setTimeout(showErr, 900);     /* greet them with a "scary" error */
  }

  return { init: init };
})();
