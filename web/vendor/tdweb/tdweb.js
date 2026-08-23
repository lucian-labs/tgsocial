(function webpackUniversalModuleDefinition(root, factory) {
	if(typeof exports === 'object' && typeof module === 'object')
		module.exports = factory();
	else if(typeof define === 'function' && define.amd)
		define("tdweb", [], factory);
	else if(typeof exports === 'object')
		exports["tdweb"] = factory();
	else
		root["tdweb"] = factory();
})(this, function() {
return /******/ (function(modules) { // webpackBootstrap
/******/ 	// The module cache
/******/ 	var installedModules = {};
/******/
/******/ 	// The require function
/******/ 	function __webpack_require__(moduleId) {
/******/
/******/ 		// Check if module is in cache
/******/ 		if(installedModules[moduleId]) {
/******/ 			return installedModules[moduleId].exports;
/******/ 		}
/******/ 		// Create a new module (and put it into the cache)
/******/ 		var module = installedModules[moduleId] = {
/******/ 			i: moduleId,
/******/ 			l: false,
/******/ 			exports: {}
/******/ 		};
/******/
/******/ 		// Execute the module function
/******/ 		modules[moduleId].call(module.exports, module, module.exports, __webpack_require__);
/******/
/******/ 		// Flag the module as loaded
/******/ 		module.l = true;
/******/
/******/ 		// Return the exports of the module
/******/ 		return module.exports;
/******/ 	}
/******/
/******/
/******/ 	// expose the modules object (__webpack_modules__)
/******/ 	__webpack_require__.m = modules;
/******/
/******/ 	// expose the module cache
/******/ 	__webpack_require__.c = installedModules;
/******/
/******/ 	// define getter function for harmony exports
/******/ 	__webpack_require__.d = function(exports, name, getter) {
/******/ 		if(!__webpack_require__.o(exports, name)) {
/******/ 			Object.defineProperty(exports, name, { enumerable: true, get: getter });
/******/ 		}
/******/ 	};
/******/
/******/ 	// define __esModule on exports
/******/ 	__webpack_require__.r = function(exports) {
/******/ 		if(typeof Symbol !== 'undefined' && Symbol.toStringTag) {
/******/ 			Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
/******/ 		}
/******/ 		Object.defineProperty(exports, '__esModule', { value: true });
/******/ 	};
/******/
/******/ 	// create a fake namespace object
/******/ 	// mode & 1: value is a module id, require it
/******/ 	// mode & 2: merge all properties of value into the ns
/******/ 	// mode & 4: return value when already ns object
/******/ 	// mode & 8|1: behave like require
/******/ 	__webpack_require__.t = function(value, mode) {
/******/ 		if(mode & 1) value = __webpack_require__(value);
/******/ 		if(mode & 8) return value;
/******/ 		if((mode & 4) && typeof value === 'object' && value && value.__esModule) return value;
/******/ 		var ns = Object.create(null);
/******/ 		__webpack_require__.r(ns);
/******/ 		Object.defineProperty(ns, 'default', { enumerable: true, value: value });
/******/ 		if(mode & 2 && typeof value != 'string') for(var key in value) __webpack_require__.d(ns, key, function(key) { return value[key]; }.bind(null, key));
/******/ 		return ns;
/******/ 	};
/******/
/******/ 	// getDefaultExport function for compatibility with non-harmony modules
/******/ 	__webpack_require__.n = function(module) {
/******/ 		var getter = module && module.__esModule ?
/******/ 			function getDefault() { return module['default']; } :
/******/ 			function getModuleExports() { return module; };
/******/ 		__webpack_require__.d(getter, 'a', getter);
/******/ 		return getter;
/******/ 	};
/******/
/******/ 	// Object.prototype.hasOwnProperty.call
/******/ 	__webpack_require__.o = function(object, property) { return Object.prototype.hasOwnProperty.call(object, property); };
/******/
/******/ 	// __webpack_public_path__
/******/ 	__webpack_require__.p = "/vendor/tdweb/";
/******/
/******/
/******/ 	// Load entry module and return exports
/******/ 	return __webpack_require__(__webpack_require__.s = 14);
/******/ })
/************************************************************************/
/******/ ([
/* 0 */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
/* WEBPACK VAR INJECTION */(function(process) {/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "b", function() { return isPromise; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "f", function() { return sleep; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "d", function() { return randomInt; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "e", function() { return randomToken; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "c", function() { return microSeconds; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "a", function() { return isNode; });
/**
 * returns true if the given object is a promise
 */
function isPromise(obj) {
  if (obj && typeof obj.then === 'function') {
    return true;
  } else {
    return false;
  }
}
function sleep(time) {
  if (!time) time = 0;
  return new Promise(function (res) {
    return setTimeout(res, time);
  });
}
function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1) + min);
}
/**
 * https://stackoverflow.com/a/1349426/3443137
 */

function randomToken(length) {
  if (!length) length = 5;
  var text = '';
  var possible = 'abcdefghijklmnopqrstuvwxzy0123456789';

  for (var i = 0; i < length; i++) {
    text += possible.charAt(Math.floor(Math.random() * possible.length));
  }

  return text;
}
var lastMs = 0;
var additional = 0;
/**
 * returns the current time in micro-seconds,
 * WARNING: This is a pseudo-function
 * Performance.now is not reliable in webworkers, so we just make sure to never return the same time.
 * This is enough in browsers, and this function will not be used in nodejs.
 * The main reason for this hack is to ensure that BroadcastChannel behaves equal to production when it is used in fast-running unit tests.
 */

function microSeconds() {
  var ms = new Date().getTime();

  if (ms === lastMs) {
    additional++;
    return ms * 1000 + additional;
  } else {
    lastMs = ms;
    additional = 0;
    return ms * 1000;
  }
}
/**
 * copied from the 'detect-node' npm module
 * We cannot use the module directly because it causes problems with rollup
 * @link https://github.com/iliakan/detect-node/blob/master/index.js
 */

var isNode = Object.prototype.toString.call(typeof process !== 'undefined' ? process : 0) === '[object process]';
/* WEBPACK VAR INJECTION */}.call(this, __webpack_require__(26)))

/***/ }),
/* 1 */
/***/ (function(module, exports, __webpack_require__) {

// TODO(Babel 8): Remove this file.

var runtime = __webpack_require__(22)();
module.exports = runtime;

// Copied from https://github.com/facebook/regenerator/blob/main/packages/runtime/runtime.js#L736=
try {
  regeneratorRuntime = runtime;
} catch (accidentalStrictMode) {
  if (typeof globalThis === "object") {
    globalThis.regeneratorRuntime = runtime;
  } else {
    Function("r", "regeneratorRuntime = r")(runtime);
  }
}


/***/ }),
/* 2 */
/***/ (function(module, exports) {

function asyncGeneratorStep(n, t, e, r, o, a, c) {
  try {
    var i = n[a](c),
      u = i.value;
  } catch (n) {
    return void e(n);
  }
  i.done ? t(u) : Promise.resolve(u).then(r, o);
}
function _asyncToGenerator(n) {
  return function () {
    var t = this,
      e = arguments;
    return new Promise(function (r, o) {
      var a = n.apply(t, e);
      function _next(n) {
        asyncGeneratorStep(a, r, o, _next, _throw, "next", n);
      }
      function _throw(n) {
        asyncGeneratorStep(a, r, o, _next, _throw, "throw", n);
      }
      _next(void 0);
    });
  };
}
module.exports = _asyncToGenerator, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 3 */
/***/ (function(module, exports) {

function _classCallCheck(a, n) {
  if (!(a instanceof n)) throw new TypeError("Cannot call a class as a function");
}
module.exports = _classCallCheck, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 4 */
/***/ (function(module, exports, __webpack_require__) {

var toPropertyKey = __webpack_require__(20);
function _defineProperties(e, r) {
  for (var t = 0; t < r.length; t++) {
    var o = r[t];
    o.enumerable = o.enumerable || !1, o.configurable = !0, "value" in o && (o.writable = !0), Object.defineProperty(e, toPropertyKey(o.key), o);
  }
}
function _createClass(e, r, t) {
  return r && _defineProperties(e.prototype, r), t && _defineProperties(e, t), Object.defineProperty(e, "prototype", {
    writable: !1
  }), e;
}
module.exports = _createClass, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 5 */
/***/ (function(module, exports) {

function _typeof(o) {
  "@babel/helpers - typeof";

  return module.exports = _typeof = "function" == typeof Symbol && "symbol" == typeof Symbol.iterator ? function (o) {
    return typeof o;
  } : function (o) {
    return o && "function" == typeof Symbol && o.constructor === Symbol && o !== Symbol.prototype ? "symbol" : typeof o;
  }, module.exports.__esModule = true, module.exports["default"] = module.exports, _typeof(o);
}
module.exports = _typeof, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 6 */
/***/ (function(module, exports) {

function _OverloadYield(e, d) {
  this.v = e, this.k = d;
}
module.exports = _OverloadYield, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 7 */
/***/ (function(module, exports, __webpack_require__) {

var regeneratorDefine = __webpack_require__(8);
function _regenerator() {
  /*! regenerator-runtime -- Copyright (c) 2014-present, Facebook, Inc. -- license (MIT): https://github.com/babel/babel/blob/main/packages/babel-helpers/LICENSE */
  var e,
    t,
    r = "function" == typeof Symbol ? Symbol : {},
    n = r.iterator || "@@iterator",
    o = r.toStringTag || "@@toStringTag";
  function i(r, n, o, i) {
    var c = n && n.prototype instanceof Generator ? n : Generator,
      u = Object.create(c.prototype);
    return regeneratorDefine(u, "_invoke", function (r, n, o) {
      var i,
        c,
        u,
        f = 0,
        p = o || [],
        y = !1,
        G = {
          p: 0,
          n: 0,
          v: e,
          a: d,
          f: d.bind(e, 4),
          d: function d(t, r) {
            return i = t, c = 0, u = e, G.n = r, a;
          }
        };
      function d(r, n) {
        for (c = r, u = n, t = 0; !y && f && !o && t < p.length; t++) {
          var o,
            i = p[t],
            d = G.p,
            l = i[2];
          r > 3 ? (o = l === n) && (u = i[(c = i[4]) ? 5 : (c = 3, 3)], i[4] = i[5] = e) : i[0] <= d && ((o = r < 2 && d < i[1]) ? (c = 0, G.v = n, G.n = i[1]) : d < l && (o = r < 3 || i[0] > n || n > l) && (i[4] = r, i[5] = n, G.n = l, c = 0));
        }
        if (o || r > 1) return a;
        throw y = !0, n;
      }
      return function (o, p, l) {
        if (f > 1) throw TypeError("Generator is already running");
        for (y && 1 === p && d(p, l), c = p, u = l; (t = c < 2 ? e : u) || !y;) {
          i || (c ? c < 3 ? (c > 1 && (G.n = -1), d(c, u)) : G.n = u : G.v = u);
          try {
            if (f = 2, i) {
              if (c || (o = "next"), t = i[o]) {
                if (!(t = t.call(i, u))) throw TypeError("iterator result is not an object");
                if (!t.done) return t;
                u = t.value, c < 2 && (c = 0);
              } else 1 === c && (t = i["return"]) && t.call(i), c < 2 && (u = TypeError("The iterator does not provide a '" + o + "' method"), c = 1);
              i = e;
            } else if ((t = (y = G.n < 0) ? u : r.call(n, G)) !== a) break;
          } catch (t) {
            i = e, c = 1, u = t;
          } finally {
            f = 1;
          }
        }
        return {
          value: t,
          done: y
        };
      };
    }(r, o, i), !0), u;
  }
  var a = {};
  function Generator() {}
  function GeneratorFunction() {}
  function GeneratorFunctionPrototype() {}
  t = Object.getPrototypeOf;
  var c = [][n] ? t(t([][n]())) : (regeneratorDefine(t = {}, n, function () {
      return this;
    }), t),
    u = GeneratorFunctionPrototype.prototype = Generator.prototype = Object.create(c);
  function f(e) {
    return Object.setPrototypeOf ? Object.setPrototypeOf(e, GeneratorFunctionPrototype) : (e.__proto__ = GeneratorFunctionPrototype, regeneratorDefine(e, o, "GeneratorFunction")), e.prototype = Object.create(u), e;
  }
  return GeneratorFunction.prototype = GeneratorFunctionPrototype, regeneratorDefine(u, "constructor", GeneratorFunctionPrototype), regeneratorDefine(GeneratorFunctionPrototype, "constructor", GeneratorFunction), GeneratorFunction.displayName = "GeneratorFunction", regeneratorDefine(GeneratorFunctionPrototype, o, "GeneratorFunction"), regeneratorDefine(u), regeneratorDefine(u, o, "Generator"), regeneratorDefine(u, n, function () {
    return this;
  }), regeneratorDefine(u, "toString", function () {
    return "[object Generator]";
  }), (module.exports = _regenerator = function _regenerator() {
    return {
      w: i,
      m: f
    };
  }, module.exports.__esModule = true, module.exports["default"] = module.exports)();
}
module.exports = _regenerator, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 8 */
/***/ (function(module, exports) {

function _regeneratorDefine(e, r, n, t) {
  var i = Object.defineProperty;
  try {
    i({}, "", {});
  } catch (e) {
    i = 0;
  }
  module.exports = _regeneratorDefine = function regeneratorDefine(e, r, n, t) {
    function o(r, n) {
      _regeneratorDefine(e, r, function (e) {
        return this._invoke(r, n, e);
      });
    }
    r ? i ? i(e, r, {
      value: n,
      enumerable: !t,
      configurable: !t,
      writable: !t
    }) : e[r] = n : (o("next", 0), o("throw", 1), o("return", 2));
  }, module.exports.__esModule = true, module.exports["default"] = module.exports, _regeneratorDefine(e, r, n, t);
}
module.exports = _regeneratorDefine, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 9 */
/***/ (function(module, exports, __webpack_require__) {

var regenerator = __webpack_require__(7);
var regeneratorAsyncIterator = __webpack_require__(10);
function _regeneratorAsyncGen(r, e, t, o, n) {
  return new regeneratorAsyncIterator(regenerator().w(r, e, t, o), n || Promise);
}
module.exports = _regeneratorAsyncGen, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 10 */
/***/ (function(module, exports, __webpack_require__) {

var OverloadYield = __webpack_require__(6);
var regeneratorDefine = __webpack_require__(8);
function AsyncIterator(t, e) {
  function n(r, o, i, f) {
    try {
      var c = t[r](o),
        u = c.value;
      return u instanceof OverloadYield ? e.resolve(u.v).then(function (t) {
        n("next", t, i, f);
      }, function (t) {
        n("throw", t, i, f);
      }) : e.resolve(u).then(function (t) {
        c.value = t, i(c);
      }, function (t) {
        return n("throw", t, i, f);
      });
    } catch (t) {
      f(t);
    }
  }
  var r;
  this.next || (regeneratorDefine(AsyncIterator.prototype), regeneratorDefine(AsyncIterator.prototype, "function" == typeof Symbol && Symbol.asyncIterator || "@asyncIterator", function () {
    return this;
  })), regeneratorDefine(this, "_invoke", function (t, o, i) {
    function f() {
      return new e(function (e, r) {
        n(t, i, e, r);
      });
    }
    return r = r ? r.then(f, f) : f();
  }, !0);
}
module.exports = AsyncIterator, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 11 */
/***/ (function(module, exports, __webpack_require__) {

var arrayWithHoles = __webpack_require__(15);
var iterableToArrayLimit = __webpack_require__(16);
var unsupportedIterableToArray = __webpack_require__(17);
var nonIterableRest = __webpack_require__(19);
function _slicedToArray(r, e) {
  return arrayWithHoles(r) || iterableToArrayLimit(r, e) || unsupportedIterableToArray(r, e) || nonIterableRest();
}
module.exports = _slicedToArray, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 12 */
/***/ (function(module, exports, __webpack_require__) {

module.exports = function() {
  return new Worker(__webpack_require__.p + "539432bc60b3c600a022.worker.js");
};

/***/ }),
/* 13 */
/***/ (function(module, exports, __webpack_require__) {

var rng = __webpack_require__(28);
var bytesToUuid = __webpack_require__(29);

function v4(options, buf, offset) {
  var i = buf && offset || 0;

  if (typeof(options) == 'string') {
    buf = options === 'binary' ? new Array(16) : null;
    options = null;
  }
  options = options || {};

  var rnds = options.random || (options.rng || rng)();

  // Per 4.4, set bits for version and `clock_seq_hi_and_reserved`
  rnds[6] = (rnds[6] & 0x0f) | 0x40;
  rnds[8] = (rnds[8] & 0x3f) | 0x80;

  // Copy bytes to buffer, if provided
  if (buf) {
    for (var ii = 0; ii < 16; ++ii) {
      buf[i + ii] = rnds[ii];
    }
  }

  return buf || bytesToUuid(rnds);
}

module.exports = v4;


/***/ }),
/* 14 */
/***/ (function(module, exports, __webpack_require__) {

module.exports = __webpack_require__(30);


/***/ }),
/* 15 */
/***/ (function(module, exports) {

function _arrayWithHoles(r) {
  if (Array.isArray(r)) return r;
}
module.exports = _arrayWithHoles, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 16 */
/***/ (function(module, exports) {

function _iterableToArrayLimit(r, l) {
  var t = null == r ? null : "undefined" != typeof Symbol && r[Symbol.iterator] || r["@@iterator"];
  if (null != t) {
    var e,
      n,
      i,
      u,
      a = [],
      f = !0,
      o = !1;
    try {
      if (i = (t = t.call(r)).next, 0 === l) {
        if (Object(t) !== t) return;
        f = !1;
      } else for (; !(f = (e = i.call(t)).done) && (a.push(e.value), a.length !== l); f = !0);
    } catch (r) {
      o = !0, n = r;
    } finally {
      try {
        if (!f && null != t["return"] && (u = t["return"](), Object(u) !== u)) return;
      } finally {
        if (o) throw n;
      }
    }
    return a;
  }
}
module.exports = _iterableToArrayLimit, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 17 */
/***/ (function(module, exports, __webpack_require__) {

var arrayLikeToArray = __webpack_require__(18);
function _unsupportedIterableToArray(r, a) {
  if (r) {
    if ("string" == typeof r) return arrayLikeToArray(r, a);
    var t = {}.toString.call(r).slice(8, -1);
    return "Object" === t && r.constructor && (t = r.constructor.name), "Map" === t || "Set" === t ? Array.from(r) : "Arguments" === t || /^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(t) ? arrayLikeToArray(r, a) : void 0;
  }
}
module.exports = _unsupportedIterableToArray, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 18 */
/***/ (function(module, exports) {

function _arrayLikeToArray(r, a) {
  (null == a || a > r.length) && (a = r.length);
  for (var e = 0, n = Array(a); e < a; e++) n[e] = r[e];
  return n;
}
module.exports = _arrayLikeToArray, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 19 */
/***/ (function(module, exports) {

function _nonIterableRest() {
  throw new TypeError("Invalid attempt to destructure non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
}
module.exports = _nonIterableRest, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 20 */
/***/ (function(module, exports, __webpack_require__) {

var _typeof = __webpack_require__(5)["default"];
var toPrimitive = __webpack_require__(21);
function toPropertyKey(t) {
  var i = toPrimitive(t, "string");
  return "symbol" == _typeof(i) ? i : i + "";
}
module.exports = toPropertyKey, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 21 */
/***/ (function(module, exports, __webpack_require__) {

var _typeof = __webpack_require__(5)["default"];
function toPrimitive(t, r) {
  if ("object" != _typeof(t) || !t) return t;
  var e = t[Symbol.toPrimitive];
  if (void 0 !== e) {
    var i = e.call(t, r || "default");
    if ("object" != _typeof(i)) return i;
    throw new TypeError("@@toPrimitive must return a primitive value.");
  }
  return ("string" === r ? String : Number)(t);
}
module.exports = toPrimitive, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 22 */
/***/ (function(module, exports, __webpack_require__) {

var OverloadYield = __webpack_require__(6);
var regenerator = __webpack_require__(7);
var regeneratorAsync = __webpack_require__(23);
var regeneratorAsyncGen = __webpack_require__(9);
var regeneratorAsyncIterator = __webpack_require__(10);
var regeneratorKeys = __webpack_require__(24);
var regeneratorValues = __webpack_require__(25);
function _regeneratorRuntime() {
  "use strict";

  var r = regenerator(),
    e = r.m(_regeneratorRuntime),
    t = (Object.getPrototypeOf ? Object.getPrototypeOf(e) : e.__proto__).constructor;
  function n(r) {
    var e = "function" == typeof r && r.constructor;
    return !!e && (e === t || "GeneratorFunction" === (e.displayName || e.name));
  }
  var o = {
    "throw": 1,
    "return": 2,
    "break": 3,
    "continue": 3
  };
  function a(r) {
    var e, t;
    return function (n) {
      e || (e = {
        stop: function stop() {
          return t(n.a, 2);
        },
        "catch": function _catch() {
          return n.v;
        },
        abrupt: function abrupt(r, e) {
          return t(n.a, o[r], e);
        },
        delegateYield: function delegateYield(r, o, a) {
          return e.resultName = o, t(n.d, regeneratorValues(r), a);
        },
        finish: function finish(r) {
          return t(n.f, r);
        }
      }, t = function t(r, _t, o) {
        n.p = e.prev, n.n = e.next;
        try {
          return r(_t, o);
        } finally {
          e.next = n.n;
        }
      }), e.resultName && (e[e.resultName] = n.v, e.resultName = void 0), e.sent = n.v, e.next = n.n;
      try {
        return r.call(this, e);
      } finally {
        n.p = e.prev, n.n = e.next;
      }
    };
  }
  return (module.exports = _regeneratorRuntime = function _regeneratorRuntime() {
    return {
      wrap: function wrap(e, t, n, o) {
        return r.w(a(e), t, n, o && o.reverse());
      },
      isGeneratorFunction: n,
      mark: r.m,
      awrap: function awrap(r, e) {
        return new OverloadYield(r, e);
      },
      AsyncIterator: regeneratorAsyncIterator,
      async: function async(r, e, t, o, u) {
        return (n(e) ? regeneratorAsyncGen : regeneratorAsync)(a(r), e, t, o, u);
      },
      keys: regeneratorKeys,
      values: regeneratorValues
    };
  }, module.exports.__esModule = true, module.exports["default"] = module.exports)();
}
module.exports = _regeneratorRuntime, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 23 */
/***/ (function(module, exports, __webpack_require__) {

var regeneratorAsyncGen = __webpack_require__(9);
function _regeneratorAsync(n, e, r, t, o) {
  var a = regeneratorAsyncGen(n, e, r, t, o);
  return a.next().then(function (n) {
    return n.done ? n.value : a.next();
  });
}
module.exports = _regeneratorAsync, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 24 */
/***/ (function(module, exports) {

function _regeneratorKeys(e) {
  var n = Object(e),
    r = [];
  for (var t in n) r.unshift(t);
  return function e() {
    for (; r.length;) if ((t = r.pop()) in n) return e.value = t, e.done = !1, e;
    return e.done = !0, e;
  };
}
module.exports = _regeneratorKeys, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 25 */
/***/ (function(module, exports, __webpack_require__) {

var _typeof = __webpack_require__(5)["default"];
function _regeneratorValues(e) {
  if (null != e) {
    var t = e["function" == typeof Symbol && Symbol.iterator || "@@iterator"],
      r = 0;
    if (t) return t.call(e);
    if ("function" == typeof e.next) return e;
    if (!isNaN(e.length)) return {
      next: function next() {
        return e && r >= e.length && (e = void 0), {
          value: e && e[r++],
          done: !e
        };
      }
    };
  }
  throw new TypeError(_typeof(e) + " is not iterable");
}
module.exports = _regeneratorValues, module.exports.__esModule = true, module.exports["default"] = module.exports;

/***/ }),
/* 26 */
/***/ (function(module, exports) {

// shim for using process in browser
var process = module.exports = {};

// cached from whatever global is present so that test runners that stub it
// don't break things.  But we need to wrap it in a try catch in case it is
// wrapped in strict mode code which doesn't define any globals.  It's inside a
// function because try/catches deoptimize in certain engines.

var cachedSetTimeout;
var cachedClearTimeout;

function defaultSetTimout() {
    throw new Error('setTimeout has not been defined');
}
function defaultClearTimeout () {
    throw new Error('clearTimeout has not been defined');
}
(function () {
    try {
        if (typeof setTimeout === 'function') {
            cachedSetTimeout = setTimeout;
        } else {
            cachedSetTimeout = defaultSetTimout;
        }
    } catch (e) {
        cachedSetTimeout = defaultSetTimout;
    }
    try {
        if (typeof clearTimeout === 'function') {
            cachedClearTimeout = clearTimeout;
        } else {
            cachedClearTimeout = defaultClearTimeout;
        }
    } catch (e) {
        cachedClearTimeout = defaultClearTimeout;
    }
} ())
function runTimeout(fun) {
    if (cachedSetTimeout === setTimeout) {
        //normal enviroments in sane situations
        return setTimeout(fun, 0);
    }
    // if setTimeout wasn't available but was latter defined
    if ((cachedSetTimeout === defaultSetTimout || !cachedSetTimeout) && setTimeout) {
        cachedSetTimeout = setTimeout;
        return setTimeout(fun, 0);
    }
    try {
        // when when somebody has screwed with setTimeout but no I.E. maddness
        return cachedSetTimeout(fun, 0);
    } catch(e){
        try {
            // When we are in I.E. but the script has been evaled so I.E. doesn't trust the global object when called normally
            return cachedSetTimeout.call(null, fun, 0);
        } catch(e){
            // same as above but when it's a version of I.E. that must have the global object for 'this', hopfully our context correct otherwise it will throw a global error
            return cachedSetTimeout.call(this, fun, 0);
        }
    }


}
function runClearTimeout(marker) {
    if (cachedClearTimeout === clearTimeout) {
        //normal enviroments in sane situations
        return clearTimeout(marker);
    }
    // if clearTimeout wasn't available but was latter defined
    if ((cachedClearTimeout === defaultClearTimeout || !cachedClearTimeout) && clearTimeout) {
        cachedClearTimeout = clearTimeout;
        return clearTimeout(marker);
    }
    try {
        // when when somebody has screwed with setTimeout but no I.E. maddness
        return cachedClearTimeout(marker);
    } catch (e){
        try {
            // When we are in I.E. but the script has been evaled so I.E. doesn't  trust the global object when called normally
            return cachedClearTimeout.call(null, marker);
        } catch (e){
            // same as above but when it's a version of I.E. that must have the global object for 'this', hopfully our context correct otherwise it will throw a global error.
            // Some versions of I.E. have different rules for clearTimeout vs setTimeout
            return cachedClearTimeout.call(this, marker);
        }
    }



}
var queue = [];
var draining = false;
var currentQueue;
var queueIndex = -1;

function cleanUpNextTick() {
    if (!draining || !currentQueue) {
        return;
    }
    draining = false;
    if (currentQueue.length) {
        queue = currentQueue.concat(queue);
    } else {
        queueIndex = -1;
    }
    if (queue.length) {
        drainQueue();
    }
}

function drainQueue() {
    if (draining) {
        return;
    }
    var timeout = runTimeout(cleanUpNextTick);
    draining = true;

    var len = queue.length;
    while(len) {
        currentQueue = queue;
        queue = [];
        while (++queueIndex < len) {
            if (currentQueue) {
                currentQueue[queueIndex].run();
            }
        }
        queueIndex = -1;
        len = queue.length;
    }
    currentQueue = null;
    draining = false;
    runClearTimeout(timeout);
}

process.nextTick = function (fun) {
    var args = new Array(arguments.length - 1);
    if (arguments.length > 1) {
        for (var i = 1; i < arguments.length; i++) {
            args[i - 1] = arguments[i];
        }
    }
    queue.push(new Item(fun, args));
    if (queue.length === 1 && !draining) {
        runTimeout(drainQueue);
    }
};

// v8 likes predictible objects
function Item(fun, array) {
    this.fun = fun;
    this.array = array;
}
Item.prototype.run = function () {
    this.fun.apply(null, this.array);
};
process.title = 'browser';
process.browser = true;
process.env = {};
process.argv = [];
process.version = ''; // empty string to avoid regexp issues
process.versions = {};

function noop() {}

process.on = noop;
process.addListener = noop;
process.once = noop;
process.off = noop;
process.removeListener = noop;
process.removeAllListeners = noop;
process.emit = noop;
process.prependListener = noop;
process.prependOnceListener = noop;

process.listeners = function (name) { return [] }

process.binding = function (name) {
    throw new Error('process.binding is not supported');
};

process.cwd = function () { return '/' };
process.chdir = function (dir) {
    throw new Error('process.chdir is not supported');
};
process.umask = function() { return 0; };


/***/ }),
/* 27 */
/***/ (function(module, exports) {

/* (ignored) */

/***/ }),
/* 28 */
/***/ (function(module, exports) {

// Unique ID creation requires a high quality random # generator.  In the
// browser this is a little complicated due to unknown quality of Math.random()
// and inconsistent support for the `crypto` API.  We do the best we can via
// feature-detection

// getRandomValues needs to be invoked in a context where "this" is a Crypto
// implementation. Also, find the complete implementation of crypto on IE11.
var getRandomValues = (typeof(crypto) != 'undefined' && crypto.getRandomValues && crypto.getRandomValues.bind(crypto)) ||
                      (typeof(msCrypto) != 'undefined' && typeof window.msCrypto.getRandomValues == 'function' && msCrypto.getRandomValues.bind(msCrypto));

if (getRandomValues) {
  // WHATWG crypto RNG - http://wiki.whatwg.org/wiki/Crypto
  var rnds8 = new Uint8Array(16); // eslint-disable-line no-undef

  module.exports = function whatwgRNG() {
    getRandomValues(rnds8);
    return rnds8;
  };
} else {
  // Math.random()-based (RNG)
  //
  // If all else fails, use Math.random().  It's fast, but is of unspecified
  // quality.
  var rnds = new Array(16);

  module.exports = function mathRNG() {
    for (var i = 0, r; i < 16; i++) {
      if ((i & 0x03) === 0) r = Math.random() * 0x100000000;
      rnds[i] = r >>> ((i & 0x03) << 3) & 0xff;
    }

    return rnds;
  };
}


/***/ }),
/* 29 */
/***/ (function(module, exports) {

/**
 * Convert array of 16 byte values to UUID string format of the form:
 * XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
 */
var byteToHex = [];
for (var i = 0; i < 256; ++i) {
  byteToHex[i] = (i + 0x100).toString(16).substr(1);
}

function bytesToUuid(buf, offset) {
  var i = offset || 0;
  var bth = byteToHex;
  // join used to fix memory issue caused by concatenation: https://bugs.chromium.org/p/v8/issues/detail?id=3175#c4
  return ([
    bth[buf[i++]], bth[buf[i++]],
    bth[buf[i++]], bth[buf[i++]], '-',
    bth[buf[i++]], bth[buf[i++]], '-',
    bth[buf[i++]], bth[buf[i++]], '-',
    bth[buf[i++]], bth[buf[i++]], '-',
    bth[buf[i++]], bth[buf[i++]],
    bth[buf[i++]], bth[buf[i++]],
    bth[buf[i++]], bth[buf[i++]]
  ]).join('');
}

module.exports = bytesToUuid;


/***/ }),
/* 30 */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
// ESM COMPAT FLAG
__webpack_require__.r(__webpack_exports__);

// EXTERNAL MODULE: ./node_modules/@babel/runtime/helpers/typeof.js
var helpers_typeof = __webpack_require__(5);
var typeof_default = /*#__PURE__*/__webpack_require__.n(helpers_typeof);

// EXTERNAL MODULE: ./node_modules/@babel/runtime/helpers/slicedToArray.js
var slicedToArray = __webpack_require__(11);
var slicedToArray_default = /*#__PURE__*/__webpack_require__.n(slicedToArray);

// EXTERNAL MODULE: ./node_modules/@babel/runtime/helpers/asyncToGenerator.js
var asyncToGenerator = __webpack_require__(2);
var asyncToGenerator_default = /*#__PURE__*/__webpack_require__.n(asyncToGenerator);

// EXTERNAL MODULE: ./node_modules/@babel/runtime/helpers/classCallCheck.js
var classCallCheck = __webpack_require__(3);
var classCallCheck_default = /*#__PURE__*/__webpack_require__.n(classCallCheck);

// EXTERNAL MODULE: ./node_modules/@babel/runtime/helpers/createClass.js
var createClass = __webpack_require__(4);
var createClass_default = /*#__PURE__*/__webpack_require__.n(createClass);

// EXTERNAL MODULE: ./node_modules/@babel/runtime/regenerator/index.js
var regenerator = __webpack_require__(1);
var regenerator_default = /*#__PURE__*/__webpack_require__.n(regenerator);

// EXTERNAL MODULE: ./src/worker.js
var worker = __webpack_require__(12);
var worker_default = /*#__PURE__*/__webpack_require__.n(worker);

// EXTERNAL MODULE: ./node_modules/broadcast-channel/dist/es/util.js
var util = __webpack_require__(0);

// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/methods/native.js

var microSeconds = util["c" /* microSeconds */];
var type = 'native';
function create(channelName) {
  var state = {
    messagesCallback: null,
    bc: new BroadcastChannel(channelName),
    subFns: [] // subscriberFunctions

  };

  state.bc.onmessage = function (msg) {
    if (state.messagesCallback) {
      state.messagesCallback(msg.data);
    }
  };

  return state;
}
function native_close(channelState) {
  channelState.bc.close();
  channelState.subFns = [];
}
function postMessage(channelState, messageJson) {
  channelState.bc.postMessage(messageJson, false);
}
function onMessage(channelState, fn) {
  channelState.messagesCallback = fn;
}
function canBeUsed() {
  /**
   * in the electron-renderer, isNode will be true even if we are in browser-context
   * so we also check if window is undefined
   */
  if (util["a" /* isNode */] && typeof window === 'undefined') return false;

  if (typeof BroadcastChannel === 'function') {
    if (BroadcastChannel._pubkey) {
      throw new Error('BroadcastChannel: Do not overwrite window.BroadcastChannel with this module, this is not a polyfill');
    }

    return true;
  } else return false;
}
function averageResponseTime() {
  return 150;
}
/* harmony default export */ var methods_native = ({
  create: create,
  close: native_close,
  onMessage: onMessage,
  postMessage: postMessage,
  canBeUsed: canBeUsed,
  type: type,
  averageResponseTime: averageResponseTime,
  microSeconds: microSeconds
});
// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/oblivious-set.js
/**
 * this is a set which automatically forgets
 * a given entry when a new entry is set and the ttl
 * of the old one is over
 * @constructor
 */
var ObliviousSet = function ObliviousSet(ttl) {
  var set = new Set();
  var timeMap = new Map();
  this.has = set.has.bind(set);

  this.add = function (value) {
    timeMap.set(value, oblivious_set_now());
    set.add(value);

    _removeTooOldValues();
  };

  this.clear = function () {
    set.clear();
    timeMap.clear();
  };

  function _removeTooOldValues() {
    var olderThen = oblivious_set_now() - ttl;
    var iterator = set[Symbol.iterator]();

    while (true) {
      var value = iterator.next().value;
      if (!value) return; // no more elements

      var time = timeMap.get(value);

      if (time < olderThen) {
        timeMap["delete"](value);
        set["delete"](value);
      } else {
        // we reached a value that is not old enough
        return;
      }
    }
  }
};

function oblivious_set_now() {
  return new Date().getTime();
}

/* harmony default export */ var oblivious_set = (ObliviousSet);
// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/options.js
function fillOptionsWithDefaults() {
  var originalOptions = arguments.length > 0 && arguments[0] !== undefined ? arguments[0] : {};
  var options = JSON.parse(JSON.stringify(originalOptions)); // main

  if (typeof options.webWorkerSupport === 'undefined') options.webWorkerSupport = true; // indexed-db

  if (!options.idb) options.idb = {}; //  after this time the messages get deleted

  if (!options.idb.ttl) options.idb.ttl = 1000 * 45;
  if (!options.idb.fallbackInterval) options.idb.fallbackInterval = 150; // localstorage

  if (!options.localstorage) options.localstorage = {};
  if (!options.localstorage.removeTimeout) options.localstorage.removeTimeout = 1000 * 60; // custom methods

  if (originalOptions.methods) options.methods = originalOptions.methods; // node

  if (!options.node) options.node = {};
  if (!options.node.ttl) options.node.ttl = 1000 * 60 * 2; // 2 minutes;

  if (typeof options.node.useFastPath === 'undefined') options.node.useFastPath = true;
  return options;
}
// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/methods/indexed-db.js
/**
 * this method uses indexeddb to store the messages
 * There is currently no observerAPI for idb
 * @link https://github.com/w3c/IndexedDB/issues/51
 */

var indexed_db_microSeconds = util["c" /* microSeconds */];


var DB_PREFIX = 'pubkey.broadcast-channel-0-';
var OBJECT_STORE_ID = 'messages';
var indexed_db_type = 'idb';
function getIdb() {
  if (typeof indexedDB !== 'undefined') return indexedDB;
  if (typeof window.mozIndexedDB !== 'undefined') return window.mozIndexedDB;
  if (typeof window.webkitIndexedDB !== 'undefined') return window.webkitIndexedDB;
  if (typeof window.msIndexedDB !== 'undefined') return window.msIndexedDB;
  return false;
}
function createDatabase(channelName) {
  var IndexedDB = getIdb(); // create table

  var dbName = DB_PREFIX + channelName;
  var openRequest = IndexedDB.open(dbName, 1);

  openRequest.onupgradeneeded = function (ev) {
    var db = ev.target.result;
    db.createObjectStore(OBJECT_STORE_ID, {
      keyPath: 'id',
      autoIncrement: true
    });
  };

  var dbPromise = new Promise(function (res, rej) {
    openRequest.onerror = function (ev) {
      return rej(ev);
    };

    openRequest.onsuccess = function () {
      res(openRequest.result);
    };
  });
  return dbPromise;
}
/**
 * writes the new message to the database
 * so other readers can find it
 */

function writeMessage(db, readerUuid, messageJson) {
  var time = new Date().getTime();
  var writeObject = {
    uuid: readerUuid,
    time: time,
    data: messageJson
  };
  var transaction = db.transaction([OBJECT_STORE_ID], 'readwrite');
  return new Promise(function (res, rej) {
    transaction.oncomplete = function () {
      return res();
    };

    transaction.onerror = function (ev) {
      return rej(ev);
    };

    var objectStore = transaction.objectStore(OBJECT_STORE_ID);
    objectStore.add(writeObject);
  });
}
function getAllMessages(db) {
  var objectStore = db.transaction(OBJECT_STORE_ID).objectStore(OBJECT_STORE_ID);
  var ret = [];
  return new Promise(function (res) {
    objectStore.openCursor().onsuccess = function (ev) {
      var cursor = ev.target.result;

      if (cursor) {
        ret.push(cursor.value); //alert("Name for SSN " + cursor.key + " is " + cursor.value.name);

        cursor["continue"]();
      } else {
        res(ret);
      }
    };
  });
}
function getMessagesHigherThen(db, lastCursorId) {
  var objectStore = db.transaction(OBJECT_STORE_ID).objectStore(OBJECT_STORE_ID);
  var ret = [];
  var keyRangeValue = IDBKeyRange.bound(lastCursorId + 1, Infinity);
  return new Promise(function (res) {
    objectStore.openCursor(keyRangeValue).onsuccess = function (ev) {
      var cursor = ev.target.result;

      if (cursor) {
        ret.push(cursor.value);
        cursor["continue"]();
      } else {
        res(ret);
      }
    };
  });
}
function removeMessageById(db, id) {
  var request = db.transaction([OBJECT_STORE_ID], 'readwrite').objectStore(OBJECT_STORE_ID)["delete"](id);
  return new Promise(function (res) {
    request.onsuccess = function () {
      return res();
    };
  });
}
function getOldMessages(db, ttl) {
  var olderThen = new Date().getTime() - ttl;
  var objectStore = db.transaction(OBJECT_STORE_ID).objectStore(OBJECT_STORE_ID);
  var ret = [];
  return new Promise(function (res) {
    objectStore.openCursor().onsuccess = function (ev) {
      var cursor = ev.target.result;

      if (cursor) {
        var msgObk = cursor.value;

        if (msgObk.time < olderThen) {
          ret.push(msgObk); //alert("Name for SSN " + cursor.key + " is " + cursor.value.name);

          cursor["continue"]();
        } else {
          // no more old messages,
          res(ret);
          return;
        }
      } else {
        res(ret);
      }
    };
  });
}
function cleanOldMessages(db, ttl) {
  return getOldMessages(db, ttl).then(function (tooOld) {
    return Promise.all(tooOld.map(function (msgObj) {
      return removeMessageById(db, msgObj.id);
    }));
  });
}
function indexed_db_create(channelName, options) {
  options = fillOptionsWithDefaults(options);
  return createDatabase(channelName).then(function (db) {
    var state = {
      closed: false,
      lastCursorId: 0,
      channelName: channelName,
      options: options,
      uuid: Object(util["e" /* randomToken */])(10),

      /**
       * emittedMessagesIds
       * contains all messages that have been emitted before
       * @type {ObliviousSet}
       */
      eMIs: new oblivious_set(options.idb.ttl * 2),
      // ensures we do not read messages in parrallel
      writeBlockPromise: Promise.resolve(),
      messagesCallback: null,
      readQueuePromises: [],
      db: db
    };
    /**
     * if service-workers are used,
     * we have no 'storage'-event if they post a message,
     * therefore we also have to set an interval
     */

    _readLoop(state);

    return state;
  });
}

function _readLoop(state) {
  if (state.closed) return;
  return readNewMessages(state).then(function () {
    return Object(util["f" /* sleep */])(state.options.idb.fallbackInterval);
  }).then(function () {
    return _readLoop(state);
  });
}

function _filterMessage(msgObj, state) {
  if (msgObj.uuid === state.uuid) return false; // send by own

  if (state.eMIs.has(msgObj.id)) return false; // already emitted

  if (msgObj.data.time < state.messagesCallbackTime) return false; // older then onMessageCallback

  return true;
}
/**
 * reads all new messages from the database and emits them
 */


function readNewMessages(state) {
  // channel already closed
  if (state.closed) return Promise.resolve(); // if no one is listening, we do not need to scan for new messages

  if (!state.messagesCallback) return Promise.resolve();
  return getMessagesHigherThen(state.db, state.lastCursorId).then(function (newerMessages) {
    var useMessages = newerMessages
    /**
     * there is a bug in iOS where the msgObj can be undefined some times
     * so we filter them out
     * @link https://github.com/pubkey/broadcast-channel/issues/19
     */
    .filter(function (msgObj) {
      return !!msgObj;
    }).map(function (msgObj) {
      if (msgObj.id > state.lastCursorId) {
        state.lastCursorId = msgObj.id;
      }

      return msgObj;
    }).filter(function (msgObj) {
      return _filterMessage(msgObj, state);
    }).sort(function (msgObjA, msgObjB) {
      return msgObjA.time - msgObjB.time;
    }); // sort by time

    useMessages.forEach(function (msgObj) {
      if (state.messagesCallback) {
        state.eMIs.add(msgObj.id);
        state.messagesCallback(msgObj.data);
      }
    });
    return Promise.resolve();
  });
}

function indexed_db_close(channelState) {
  channelState.closed = true;
  channelState.db.close();
}
function indexed_db_postMessage(channelState, messageJson) {
  channelState.writeBlockPromise = channelState.writeBlockPromise.then(function () {
    return writeMessage(channelState.db, channelState.uuid, messageJson);
  }).then(function () {
    if (Object(util["d" /* randomInt */])(0, 10) === 0) {
      /* await (do not await) */
      cleanOldMessages(channelState.db, channelState.options.idb.ttl);
    }
  });
  return channelState.writeBlockPromise;
}
function indexed_db_onMessage(channelState, fn, time) {
  channelState.messagesCallbackTime = time;
  channelState.messagesCallback = fn;
  readNewMessages(channelState);
}
function indexed_db_canBeUsed() {
  if (util["a" /* isNode */]) return false;
  var idb = getIdb();
  if (!idb) return false;
  return true;
}
function indexed_db_averageResponseTime(options) {
  return options.idb.fallbackInterval * 2;
}
/* harmony default export */ var indexed_db = ({
  create: indexed_db_create,
  close: indexed_db_close,
  onMessage: indexed_db_onMessage,
  postMessage: indexed_db_postMessage,
  canBeUsed: indexed_db_canBeUsed,
  type: indexed_db_type,
  averageResponseTime: indexed_db_averageResponseTime,
  microSeconds: indexed_db_microSeconds
});
// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/methods/localstorage.js
/**
 * A localStorage-only method which uses localstorage and its 'storage'-event
 * This does not work inside of webworkers because they have no access to locastorage
 * This is basically implemented to support IE9 or your grandmothers toaster.
 * @link https://caniuse.com/#feat=namevalue-storage
 * @link https://caniuse.com/#feat=indexeddb
 */



var localstorage_microSeconds = util["c" /* microSeconds */];
var KEY_PREFIX = 'pubkey.broadcastChannel-';
var localstorage_type = 'localstorage';
/**
 * copied from crosstab
 * @link https://github.com/tejacques/crosstab/blob/master/src/crosstab.js#L32
 */

function getLocalStorage() {
  var localStorage;
  if (typeof window === 'undefined') return null;

  try {
    localStorage = window.localStorage;
    localStorage = window['ie8-eventlistener/storage'] || window.localStorage;
  } catch (e) {// New versions of Firefox throw a Security exception
    // if cookies are disabled. See
    // https://bugzilla.mozilla.org/show_bug.cgi?id=1028153
  }

  return localStorage;
}
function storageKey(channelName) {
  return KEY_PREFIX + channelName;
}
/**
* writes the new message to the storage
* and fires the storage-event so other readers can find it
*/

function localstorage_postMessage(channelState, messageJson) {
  return new Promise(function (res) {
    Object(util["f" /* sleep */])().then(function () {
      var key = storageKey(channelState.channelName);
      var writeObj = {
        token: Object(util["e" /* randomToken */])(10),
        time: new Date().getTime(),
        data: messageJson,
        uuid: channelState.uuid
      };
      var value = JSON.stringify(writeObj);
      getLocalStorage().setItem(key, value);
      /**
       * StorageEvent does not fire the 'storage' event
       * in the window that changes the state of the local storage.
       * So we fire it manually
       */

      var ev = document.createEvent('Event');
      ev.initEvent('storage', true, true);
      ev.key = key;
      ev.newValue = value;
      window.dispatchEvent(ev);
      res();
    });
  });
}
function addStorageEventListener(channelName, fn) {
  var key = storageKey(channelName);

  var listener = function listener(ev) {
    if (ev.key === key) {
      fn(JSON.parse(ev.newValue));
    }
  };

  window.addEventListener('storage', listener);
  return listener;
}
function removeStorageEventListener(listener) {
  window.removeEventListener('storage', listener);
}
function localstorage_create(channelName, options) {
  options = fillOptionsWithDefaults(options);

  if (!localstorage_canBeUsed()) {
    throw new Error('BroadcastChannel: localstorage cannot be used');
  }

  var uuid = Object(util["e" /* randomToken */])(10);
  /**
   * eMIs
   * contains all messages that have been emitted before
   * @type {ObliviousSet}
   */

  var eMIs = new oblivious_set(options.localstorage.removeTimeout);
  var state = {
    channelName: channelName,
    uuid: uuid,
    eMIs: eMIs // emittedMessagesIds

  };
  state.listener = addStorageEventListener(channelName, function (msgObj) {
    if (!state.messagesCallback) return; // no listener

    if (msgObj.uuid === uuid) return; // own message

    if (!msgObj.token || eMIs.has(msgObj.token)) return; // already emitted

    if (msgObj.data.time && msgObj.data.time < state.messagesCallbackTime) return; // too old

    eMIs.add(msgObj.token);
    state.messagesCallback(msgObj.data);
  });
  return state;
}
function localstorage_close(channelState) {
  removeStorageEventListener(channelState.listener);
}
function localstorage_onMessage(channelState, fn, time) {
  channelState.messagesCallbackTime = time;
  channelState.messagesCallback = fn;
}
function localstorage_canBeUsed() {
  if (util["a" /* isNode */]) return false;
  var ls = getLocalStorage();
  if (!ls) return false;

  try {
    var key = '__broadcastchannel_check';
    ls.setItem(key, 'works');
    ls.removeItem(key);
  } catch (e) {
    // Safari 10 in private mode will not allow write access to local
    // storage and fail with a QuotaExceededError. See
    // https://developer.mozilla.org/en-US/docs/Web/API/Web_Storage_API#Private_Browsing_Incognito_modes
    return false;
  }

  return true;
}
function localstorage_averageResponseTime() {
  return 120;
}
/* harmony default export */ var localstorage = ({
  create: localstorage_create,
  close: localstorage_close,
  onMessage: localstorage_onMessage,
  postMessage: localstorage_postMessage,
  canBeUsed: localstorage_canBeUsed,
  type: localstorage_type,
  averageResponseTime: localstorage_averageResponseTime,
  microSeconds: localstorage_microSeconds
});
// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/methods/simulate.js

var simulate_microSeconds = util["c" /* microSeconds */];
var simulate_type = 'simulate';
var SIMULATE_CHANNELS = new Set();
function simulate_create(channelName) {
  var state = {
    name: channelName,
    messagesCallback: null
  };
  SIMULATE_CHANNELS.add(state);
  return state;
}
function simulate_close(channelState) {
  SIMULATE_CHANNELS["delete"](channelState);
}
function simulate_postMessage(channelState, messageJson) {
  return new Promise(function (res) {
    return setTimeout(function () {
      var channelArray = Array.from(SIMULATE_CHANNELS);
      channelArray.filter(function (channel) {
        return channel.name === channelState.name;
      }).filter(function (channel) {
        return channel !== channelState;
      }).filter(function (channel) {
        return !!channel.messagesCallback;
      }).forEach(function (channel) {
        return channel.messagesCallback(messageJson);
      });
      res();
    }, 5);
  });
}
function simulate_onMessage(channelState, fn) {
  channelState.messagesCallback = fn;
}
function simulate_canBeUsed() {
  return true;
}
function simulate_averageResponseTime() {
  return 5;
}
/* harmony default export */ var simulate = ({
  create: simulate_create,
  close: simulate_close,
  onMessage: simulate_onMessage,
  postMessage: simulate_postMessage,
  canBeUsed: simulate_canBeUsed,
  type: simulate_type,
  averageResponseTime: simulate_averageResponseTime,
  microSeconds: simulate_microSeconds
});
// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/method-chooser.js




 // order is important

var METHODS = [methods_native, // fastest
indexed_db, localstorage];
/**
 * The NodeMethod is loaded lazy
 * so it will not get bundled in browser-builds
 */

if (util["a" /* isNode */]) {
  /**
   * we use the non-transpiled code for nodejs
   * because it runs faster
   */
  var NodeMethod = __webpack_require__(27);
  /**
   * this will be false for webpackbuilds
   * which will shim the node-method with an empty object {}
   */


  if (typeof NodeMethod.canBeUsed === 'function') {
    METHODS.push(NodeMethod);
  }
}

function chooseMethod(options) {
  var chooseMethods = [].concat(options.methods, METHODS).filter(Boolean); // directly chosen

  if (options.type) {
    if (options.type === 'simulate') {
      // only use simulate-method if directly chosen
      return simulate;
    }

    var ret = chooseMethods.find(function (m) {
      return m.type === options.type;
    });
    if (!ret) throw new Error('method-type ' + options.type + ' not found');else return ret;
  }
  /**
   * if no webworker support is needed,
   * remove idb from the list so that localstorage is been chosen
   */


  if (!options.webWorkerSupport && !util["a" /* isNode */]) {
    chooseMethods = chooseMethods.filter(function (m) {
      return m.type !== 'idb';
    });
  }

  var useMethod = chooseMethods.find(function (method) {
    return method.canBeUsed();
  });
  if (!useMethod) throw new Error('No useable methode found:' + JSON.stringify(METHODS.map(function (m) {
    return m.type;
  })));else return useMethod;
}
// CONCATENATED MODULE: ./node_modules/broadcast-channel/dist/es/index.js




var es_BroadcastChannel = function BroadcastChannel(name, options) {
  this.name = name;

  if (ENFORCED_OPTIONS) {
    options = ENFORCED_OPTIONS;
  }

  this.options = fillOptionsWithDefaults(options);
  this.method = chooseMethod(this.options); // isListening

  this._iL = false;
  /**
   * _onMessageListener
   * setting onmessage twice,
   * will overwrite the first listener
   */

  this._onML = null;
  /**
   * _addEventListeners
   */

  this._addEL = {
    message: [],
    internal: []
  };
  /**
   * _beforeClose
   * array of promises that will be awaited
   * before the channel is closed
   */

  this._befC = [];
  /**
   * _preparePromise
   */

  this._prepP = null;

  _prepareChannel(this);
}; // STATICS

/**
 * used to identify if someone overwrites
 * window.BroadcastChannel with this
 * See methods/native.js
 */


es_BroadcastChannel._pubkey = true;
/**
 * clears the tmp-folder if is node
 * @return {Promise<boolean>} true if has run, false if not node
 */

es_BroadcastChannel.clearNodeFolder = function (options) {
  options = fillOptionsWithDefaults(options);
  var method = chooseMethod(options);

  if (method.type === 'node') {
    return method.clearNodeFolder().then(function () {
      return true;
    });
  } else {
    return Promise.resolve(false);
  }
};
/**
 * if set, this method is enforced,
 * no mather what the options are
 */


var ENFORCED_OPTIONS;

es_BroadcastChannel.enforceOptions = function (options) {
  ENFORCED_OPTIONS = options;
}; // PROTOTYPE


es_BroadcastChannel.prototype = {
  postMessage: function postMessage(msg) {
    if (this.closed) {
      throw new Error('BroadcastChannel.postMessage(): ' + 'Cannot post message after channel has closed');
    }

    return _post(this, 'message', msg);
  },
  postInternal: function postInternal(msg) {
    return _post(this, 'internal', msg);
  },

  set onmessage(fn) {
    var time = this.method.microSeconds();
    var listenObj = {
      time: time,
      fn: fn
    };

    _removeListenerObject(this, 'message', this._onML);

    if (fn && typeof fn === 'function') {
      this._onML = listenObj;

      _addListenerObject(this, 'message', listenObj);
    } else {
      this._onML = null;
    }
  },

  addEventListener: function addEventListener(type, fn) {
    var time = this.method.microSeconds();
    var listenObj = {
      time: time,
      fn: fn
    };

    _addListenerObject(this, type, listenObj);
  },
  removeEventListener: function removeEventListener(type, fn) {
    var obj = this._addEL[type].find(function (obj) {
      return obj.fn === fn;
    });

    _removeListenerObject(this, type, obj);
  },
  close: function close() {
    var _this = this;

    if (this.closed) return;
    this.closed = true;
    var awaitPrepare = this._prepP ? this._prepP : Promise.resolve();
    this._onML = null;
    this._addEL.message = [];
    return awaitPrepare.then(function () {
      return Promise.all(_this._befC.map(function (fn) {
        return fn();
      }));
    }).then(function () {
      return _this.method.close(_this._state);
    });
  },

  get type() {
    return this.method.type;
  }

};

function _post(broadcastChannel, type, msg) {
  var time = broadcastChannel.method.microSeconds();
  var msgObj = {
    time: time,
    type: type,
    data: msg
  };
  var awaitPrepare = broadcastChannel._prepP ? broadcastChannel._prepP : Promise.resolve();
  return awaitPrepare.then(function () {
    return broadcastChannel.method.postMessage(broadcastChannel._state, msgObj);
  });
}

function _prepareChannel(channel) {
  var maybePromise = channel.method.create(channel.name, channel.options);

  if (Object(util["b" /* isPromise */])(maybePromise)) {
    channel._prepP = maybePromise;
    maybePromise.then(function (s) {
      // used in tests to simulate slow runtime

      /*if (channel.options.prepareDelay) {
           await new Promise(res => setTimeout(res, this.options.prepareDelay));
      }*/
      channel._state = s;
    });
  } else {
    channel._state = maybePromise;
  }
}

function _hasMessageListeners(channel) {
  if (channel._addEL.message.length > 0) return true;
  if (channel._addEL.internal.length > 0) return true;
  return false;
}

function _addListenerObject(channel, type, obj) {
  channel._addEL[type].push(obj);

  _startListening(channel);
}

function _removeListenerObject(channel, type, obj) {
  channel._addEL[type] = channel._addEL[type].filter(function (o) {
    return o !== obj;
  });

  _stopListening(channel);
}

function _startListening(channel) {
  if (!channel._iL && _hasMessageListeners(channel)) {
    // someone is listening, start subscribing
    var listenerFn = function listenerFn(msgObj) {
      channel._addEL[msgObj.type].forEach(function (obj) {
        if (msgObj.time >= obj.time) {
          obj.fn(msgObj.data);
        }
      });
    };

    var time = channel.method.microSeconds();

    if (channel._prepP) {
      channel._prepP.then(function () {
        channel._iL = true;
        channel.method.onMessage(channel._state, listenerFn, time);
      });
    } else {
      channel._iL = true;
      channel.method.onMessage(channel._state, listenerFn, time);
    }
  }
}

function _stopListening(channel) {
  if (channel._iL && !_hasMessageListeners(channel)) {
    // noone is listening, stop subscribing
    channel._iL = false;
    var time = channel.method.microSeconds();
    channel.method.onMessage(channel._state, null, time);
  }
}

/* harmony default export */ var es = (es_BroadcastChannel);
// EXTERNAL MODULE: ./node_modules/uuid/v4.js
var v4 = __webpack_require__(13);
var v4_default = /*#__PURE__*/__webpack_require__.n(v4);

// CONCATENATED MODULE: ./src/logger.js


var logger_Logger = /*#__PURE__*/function () {
  function Logger() {
    classCallCheck_default()(this, Logger);
    this.setVerbosity('WARNING');
  }
  return createClass_default()(Logger, [{
    key: "debug",
    value: function debug() {
      if (this.checkVerbosity(4)) {
        var _console;
        (_console = console).log.apply(_console, arguments);
      }
    }
  }, {
    key: "log",
    value: function log() {
      if (this.checkVerbosity(4)) {
        var _console2;
        (_console2 = console).log.apply(_console2, arguments);
      }
    }
  }, {
    key: "info",
    value: function info() {
      if (this.checkVerbosity(3)) {
        var _console3;
        (_console3 = console).info.apply(_console3, arguments);
      }
    }
  }, {
    key: "warn",
    value: function warn() {
      if (this.checkVerbosity(2)) {
        var _console4;
        (_console4 = console).warn.apply(_console4, arguments);
      }
    }
  }, {
    key: "error",
    value: function error() {
      if (this.checkVerbosity(1)) {
        var _console5;
        (_console5 = console).error.apply(_console5, arguments);
      }
    }
  }, {
    key: "setVerbosity",
    value: function setVerbosity(level) {
      var default_level = arguments.length > 1 && arguments[1] !== undefined ? arguments[1] : 'info';
      if (level === undefined) {
        level = default_level;
      }
      if (typeof level === 'string') {
        level = {
          ERROR: 1,
          WARNING: 2,
          INFO: 3,
          LOG: 4,
          DEBUG: 4
        }[level.toUpperCase()] || 2;
      }
      this.level = level;
    }
  }, {
    key: "checkVerbosity",
    value: function checkVerbosity(level) {
      return this.level >= level;
    }
  }]);
}();
var log = new logger_Logger();
/* harmony default export */ var logger = (log);
// CONCATENATED MODULE: ./src/index.js





function _createForOfIteratorHelper(r, e) { var t = "undefined" != typeof Symbol && r[Symbol.iterator] || r["@@iterator"]; if (!t) { if (Array.isArray(r) || (t = _unsupportedIterableToArray(r)) || e && r && "number" == typeof r.length) { t && (r = t); var _n = 0, F = function F() {}; return { s: F, n: function n() { return _n >= r.length ? { done: !0 } : { done: !1, value: r[_n++] }; }, e: function e(r) { throw r; }, f: F }; } throw new TypeError("Invalid attempt to iterate non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method."); } var o, a = !0, u = !1; return { s: function s() { t = t.call(r); }, n: function n() { var r = t.next(); return a = r.done, r; }, e: function e(r) { u = !0, o = r; }, f: function f() { try { a || null == t["return"] || t["return"](); } finally { if (u) throw o; } } }; }
function _unsupportedIterableToArray(r, a) { if (r) { if ("string" == typeof r) return _arrayLikeToArray(r, a); var t = {}.toString.call(r).slice(8, -1); return "Object" === t && r.constructor && (t = r.constructor.name), "Map" === t || "Set" === t ? Array.from(r) : "Arguments" === t || /^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(t) ? _arrayLikeToArray(r, a) : void 0; } }
function _arrayLikeToArray(r, a) { (null == a || a > r.length) && (a = r.length); for (var e = 0, n = Array(a); e < a; e++) n[e] = r[e]; return n; }


//import localforage from 'localforage';



var sleep = function sleep(ms) {
  return new Promise(function (res) {
    return setTimeout(res, ms);
  });
};

/**
 * TDLib in a browser
 *
 * TDLib can be compiled to WebAssembly using Emscripten compiler and used in a browser from JavaScript.
 * This is a convenient wrapper for TDLib in a browser which controls TDLib instance creation, handles interaction
 * with TDLib and manages a filesystem for persistent TDLib data.
 * TDLib instance is created in a Web Worker to run it in a separate thread.
 * TdClient just sends queries to the Web Worker and receives updates and results from it.
 * <br>
 * <br>
 * Differences from the TDLib JSON API:<br>
 * 1. Added the update <code>updateFatalError error:string = Update;</code> which is sent whenever TDLib encounters a fatal error.<br>
 * 2. Added the method <code>setJsLogVerbosityLevel new_verbosity_level:string = Ok;</code>, which allows to change the verbosity level of tdweb logging.<br>
 * 3. Added the possibility to use blobs as input files via the constructor <code>inputFileBlob data:<JavaScript blob> = InputFile;</code>.<br>
 * 4. The class <code>filePart</code> contains data as a JavaScript blob instead of a base64-encoded string.<br>
 * 5. The methods <code>getStorageStatistics</code>, <code>getStorageStatisticsFast</code>, <code>optimizeStorage</code>, and <code>addProxy</code> are not supported.<br>
 * <br>
 */
var src_TdClient = /*#__PURE__*/function () {
  /**
   * @callback TdClient~updateCallback
   * @param {Object} update The update.
   */

  /**
   * Create TdClient.
   * @param {Object} options - Options for TDLib instance creation.
   * @param {TdClient~updateCallback} options.onUpdate - Callback for all incoming updates.
   * @param {string} [options.instanceName=tdlib] - Name of the TDLib instance. Currently, only one instance of TdClient with a given name is allowed. All but one instances with the same name will be automatically closed. Usually, the newest non-background instance is kept alive. Files will be stored in an IndexedDb table with the same name.
   * @param {boolean} [options.isBackground=false] - Pass true if the instance is opened from the background.
   * @param {string} [options.jsLogVerbosityLevel=info] - The initial verbosity level of the JavaScript part of the code (one of 'error', 'warning', 'info', 'log', 'debug').
   * @param {number} [options.logVerbosityLevel=2] - The initial verbosity level for the TDLib internal logging (0-1023).
   * @param {boolean} [options.useDatabase=true] - Pass false to use TDLib without database and secret chats. It significantly improves loading time, but some functionality is unavailable without the database.
   * @param {boolean} [options.readOnly=false] - For debug only. Pass true to open TDLib database in read-only mode
   */
  function TdClient(options) {
    var _this = this;
    classCallCheck_default()(this, TdClient);
    logger.setVerbosity(options.jsLogVerbosityLevel);
    this.worker = new worker_default.a();
    this.worker.onmessage = function (e) {
      _this.onResponse(e.data);
    };
    this.query_id = 0;
    this.query_callbacks = new Map();
    if ('onUpdate' in options) {
      this.onUpdate = options.onUpdate;
      delete options.onUpdate;
    }
    options.instanceName = options.instanceName || 'tdlib';
    this.fileManager = new src_FileManager(options.instanceName, this);
    this.worker.postMessage({
      '@type': 'init',
      options: options
    });
    this.closeOtherClients(options);
  }

  /**
   * Send a query to TDLib.
   *
   * If the query contains the field '@extra', the same field will be added into the result.
   *
   * @param {Object} query - The query for TDLib. See the [td_api.tl]{@link https://github.com/tdlib/td/blob/master/td/generate/scheme/td_api.tl} scheme or
   *                         the automatically generated [HTML documentation]{@link https://core.telegram.org/tdlib/docs/td__api_8h.html}
   *                         for a list of all available TDLib [methods]{@link https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1_function.html} and
   *                         [classes]{@link https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1_object.html}.
   * @returns {Promise} Promise object represents the result of the query.
   */
  return createClass_default()(TdClient, [{
    key: "send",
    value: function send(query) {
      return this.doSend(query, true);
    }

    /** @private */
  }, {
    key: "sendInternal",
    value: function sendInternal(query) {
      return this.doSend(query, false);
    }
    /** @private */
  }, {
    key: "doSend",
    value: function doSend(query, isExternal) {
      var _this2 = this;
      this.query_id++;
      if (query['@extra']) {
        query['@extra'] = {
          '@old_extra': JSON.parse(JSON.stringify(query['@extra'])),
          query_id: this.query_id
        };
      } else {
        query['@extra'] = {
          query_id: this.query_id
        };
      }
      if (query['@type'] === 'setJsLogVerbosityLevel') {
        logger.setVerbosity(query.new_verbosity_level);
      }
      logger.debug('send to worker: ', query);
      var res = new Promise(function (resolve, reject) {
        _this2.query_callbacks.set(_this2.query_id, [resolve, reject]);
      });
      if (isExternal) {
        this.externalPostMessage(query);
      } else {
        this.worker.postMessage(query);
      }
      return res;
    }

    /** @private */
  }, {
    key: "externalPostMessage",
    value: function externalPostMessage(query) {
      var unsupportedMethods = ['getStorageStatistics', 'getStorageStatisticsFast', 'optimizeStorage', 'addProxy', 'init', 'start'];
      if (unsupportedMethods.includes(query['@type'])) {
        this.onResponse({
          '@type': 'error',
          '@extra': query['@extra'],
          code: 400,
          message: "Method '" + query['@type'] + "' is not supported"
        });
        return;
      }
      if (query['@type'] === 'readFile' || query['@type'] === 'readFilePart') {
        this.readFile(query);
        return;
      }
      if (query['@type'] === 'deleteFile') {
        this.deleteFile(query);
        return;
      }
      this.worker.postMessage(query);
    }

    /** @private */
  }, {
    key: "readFile",
    value: (function () {
      var _readFile = asyncToGenerator_default()(/*#__PURE__*/regenerator_default.a.mark(function _callee(query) {
        var response;
        return regenerator_default.a.wrap(function (_context) {
          while (1) switch (_context.prev = _context.next) {
            case 0:
              _context.next = 1;
              return this.fileManager.readFile(query);
            case 1:
              response = _context.sent;
              this.onResponse(response);
            case 2:
            case "end":
              return _context.stop();
          }
        }, _callee, this);
      }));
      function readFile(_x) {
        return _readFile.apply(this, arguments);
      }
      return readFile;
    }() /** @private */)
  }, {
    key: "deleteFile",
    value: (function () {
      var _deleteFile = asyncToGenerator_default()(/*#__PURE__*/regenerator_default.a.mark(function _callee2(query) {
        var response, _t;
        return regenerator_default.a.wrap(function (_context2) {
          while (1) switch (_context2.prev = _context2.next) {
            case 0:
              response = this.fileManager.deleteFile(query);
              _context2.prev = 1;
              if (!response.idb_key) {
                _context2.next = 3;
                break;
              }
              _context2.next = 2;
              return this.sendInternal({
                '@type': 'deleteIdbKey',
                idb_key: response.idb_key
              });
            case 2:
              delete response.idb_key;
            case 3:
              _context2.next = 4;
              return this.sendInternal({
                '@type': 'deleteFile',
                file_id: query.file_id
              });
            case 4:
              _context2.next = 6;
              break;
            case 5:
              _context2.prev = 5;
              _t = _context2["catch"](1);
            case 6:
              this.onResponse(response);
            case 7:
            case "end":
              return _context2.stop();
          }
        }, _callee2, this, [[1, 5]]);
      }));
      function deleteFile(_x2) {
        return _deleteFile.apply(this, arguments);
      }
      return deleteFile;
    }() /** @private */)
  }, {
    key: "onResponse",
    value: function onResponse(response) {
      logger.debug('receive from worker: ', JSON.parse(JSON.stringify(response, function (key, value) {
        if (key === 'arr' || key === 'data') {
          return undefined;
        }
        return value;
      })));

      // for FileManager
      response = this.prepareResponse(response);
      if ('@extra' in response) {
        var query_id = response['@extra'].query_id;
        var _this$query_callbacks = this.query_callbacks.get(query_id),
          _this$query_callbacks2 = slicedToArray_default()(_this$query_callbacks, 2),
          resolve = _this$query_callbacks2[0],
          reject = _this$query_callbacks2[1];
        this.query_callbacks["delete"](query_id);
        if ('@old_extra' in response['@extra']) {
          response['@extra'] = response['@extra']['@old_extra'];
        }
        if (resolve) {
          if (response['@type'] === 'error') {
            reject(response);
          } else {
            resolve(response);
          }
        }
      } else {
        if (response['@type'] === 'inited') {
          this.onInited();
          return;
        }
        if (response['@type'] === 'fsInited') {
          this.onFsInited();
          return;
        }
        if (response['@type'] === 'updateAuthorizationState' && response.authorization_state['@type'] === 'authorizationStateClosed') {
          this.onClosed();
        }
        this.onUpdate(response);
      }
    }

    /** @private */
  }, {
    key: "prepareFile",
    value: function prepareFile(file) {
      return this.fileManager.registerFile(file);
    }

    /** @private */
  }, {
    key: "prepareResponse",
    value: function prepareResponse(response) {
      var _this3 = this;
      if (response['@type'] === 'file') {
        if (false) {}
        return this.prepareFile(response);
      }
      for (var key in response) {
        var field = response[key];
        if (field && typeof_default()(field) === 'object' && key !== 'data' && key !== 'arr') {
          response[key] = this.prepareResponse(field);
        }
      }
      return response;
    }

    /** @private */
  }, {
    key: "onBroadcastMessage",
    value: function onBroadcastMessage(e) {
      //const message = e.data;
      var message = e;
      if (message.uid === this.uid) {
        logger.info('ignore self broadcast message: ', message);
        return;
      }
      logger.info('receive broadcast message: ', message);
      if (message.isBackground && !this.isBackground) {
        // continue
      } else if (!message.isBackground && this.isBackground || message.timestamp > this.timestamp) {
        this.close();
        return;
      }
      if (message.state === 'closed') {
        this.waitSet["delete"](message.uid);
        if (this.waitSet.size === 0) {
          logger.info('onWaitSetEmpty');
          this.onWaitSetEmpty();
          this.onWaitSetEmpty = function () {};
        }
      } else {
        this.waitSet.add(message.uid);
        if (message.state !== 'closing') {
          this.postState();
        }
      }
    }

    /** @private */
  }, {
    key: "postState",
    value: function postState() {
      var state = {
        uid: this.uid,
        state: this.state,
        timestamp: this.timestamp,
        isBackground: this.isBackground
      };
      logger.info('Post state: ', state);
      this.channel.postMessage(state);
    }

    /** @private */
  }, {
    key: "onWaitSetEmpty",
    value: function onWaitSetEmpty() {
      // nop
    }

    /** @private */
  }, {
    key: "onFsInited",
    value: function onFsInited() {
      this.fileManager.init();
    }

    /** @private */
  }, {
    key: "onInited",
    value: function onInited() {
      this.isInited = true;
      this.doSendStart();
    }

    /** @private */
  }, {
    key: "sendStart",
    value: function sendStart() {
      this.wantSendStart = true;
      this.doSendStart();
    }

    /** @private */
  }, {
    key: "doSendStart",
    value: function doSendStart() {
      if (!this.isInited || !this.wantSendStart || this.state !== 'start') {
        return;
      }
      this.wantSendStart = false;
      this.state = 'active';
      var query = {
        '@type': 'start'
      };
      logger.info('send to worker: ', query);
      this.worker.postMessage(query);
    }

    /** @private */
  }, {
    key: "onClosed",
    value: function onClosed() {
      this.isClosing = true;
      this.worker.terminate();
      logger.info('worker is terminated');
      this.state = 'closed';
      this.postState();
    }

    /** @private */
  }, {
    key: "close",
    value: function close() {
      if (this.isClosing) {
        return;
      }
      this.isClosing = true;
      logger.info('close state: ', this.state);
      if (this.state === 'start') {
        this.onClosed();
        this.onUpdate({
          '@type': 'updateAuthorizationState',
          authorization_state: {
            '@type': 'authorizationStateClosed'
          }
        });
        return;
      }
      var query = {
        '@type': 'close'
      };
      logger.info('send to worker: ', query);
      this.worker.postMessage(query);
      this.state = 'closing';
      this.postState();
    }

    /** @private */
  }, {
    key: "closeOtherClients",
    value: (function () {
      var _closeOtherClients = asyncToGenerator_default()(/*#__PURE__*/regenerator_default.a.mark(function _callee4(options) {
        var _this4 = this;
        return regenerator_default.a.wrap(function (_context4) {
          while (1) switch (_context4.prev = _context4.next) {
            case 0:
              this.uid = v4_default()();
              this.state = 'start';
              this.isBackground = !!options.isBackground;
              this.timestamp = Date.now();
              this.waitSet = new Set();
              logger.info('close other clients');
              this.channel = new es(options.instanceName, {
                webWorkerSupport: false
              });
              this.postState();
              this.channel.onmessage = function (message) {
                _this4.onBroadcastMessage(message);
              };
              _context4.next = 1;
              return sleep(300);
            case 1:
              if (!(this.waitSet.size !== 0)) {
                _context4.next = 2;
                break;
              }
              _context4.next = 2;
              return new Promise(function (resolve) {
                _this4.onWaitSetEmpty = resolve;
              });
            case 2:
              this.sendStart();
            case 3:
            case "end":
              return _context4.stop();
          }
        }, _callee4, this);
      }));
      function closeOtherClients(_x3) {
        return _closeOtherClients.apply(this, arguments);
      }
      return closeOtherClients;
    }() /** @private */)
  }, {
    key: "onUpdate",
    value: function onUpdate(update) {
      logger.info('ignore onUpdate');
      //nop
    }
  }]);
}();
/** @private */
var src_ListNode = /*#__PURE__*/function () {
  function ListNode(value) {
    classCallCheck_default()(this, ListNode);
    this.value = value;
    this.clear();
  }
  return createClass_default()(ListNode, [{
    key: "erase",
    value: function erase() {
      this.prev.connect(this.next);
      this.clear();
    }
  }, {
    key: "clear",
    value: function clear() {
      this.prev = this;
      this.next = this;
    }
  }, {
    key: "connect",
    value: function connect(other) {
      this.next = other;
      other.prev = this;
    }
  }, {
    key: "onUsed",
    value: function onUsed(other) {
      other.usedAt = Date.now();
      other.erase();
      other.connect(this.next);
      logger.debug('LRU: used file_id: ', other.value);
      this.connect(other);
    }
  }, {
    key: "getLru",
    value: function getLru() {
      if (this === this.next) {
        throw new Error('popLru from empty list');
      }
      return this.prev;
    }
  }]);
}();
/** @private */
var src_FileManager = /*#__PURE__*/function () {
  function FileManager(instanceName, client) {
    classCallCheck_default()(this, FileManager);
    this.instanceName = instanceName;
    this.cache = new Map();
    this.pending = [];
    this.transaction_id = 0;
    this.totalSize = 0;
    this.lru = new src_ListNode(-1);
    this.client = client;
  }
  return createClass_default()(FileManager, [{
    key: "init",
    value: function init() {
      var _this5 = this;
      this.idb = new Promise(function (resolve, reject) {
        var request = indexedDB.open(_this5.instanceName);
        request.onsuccess = function () {
          return resolve(request.result);
        };
        request.onerror = function () {
          return reject(request.error);
        };
      });
      //this.store = localforage.createInstance({
      //name: instanceName
      //});
      this.isInited = true;
    }
  }, {
    key: "unload",
    value: function unload(info) {
      if (info.arr) {
        logger.debug('LRU: delete file_id: ', info.node.value, ' with arr.length: ', info.arr.length);
        this.totalSize -= info.arr.length;
        delete info.arr;
      }
      if (info.node) {
        info.node.erase();
        delete info.node;
      }
    }
  }, {
    key: "registerFile",
    value: function registerFile(file) {
      if (file.idb_key || file.arr) {
        file.local.is_downloading_completed = true;
      } else {
        file.local.is_downloading_completed = false;
      }
      var info = {};
      var cached_info = this.cache.get(file.id);
      if (cached_info) {
        info = cached_info;
      } else {
        this.cache.set(file.id, info);
      }
      if (file.idb_key) {
        info.idb_key = file.idb_key;
        delete file.idb_key;
      } else {
        delete info.idb_key;
      }
      if (file.arr) {
        var now = Date.now();
        while (this.totalSize > 100000000) {
          var node = this.lru.getLru();
          // immunity for 60 seconds
          if (node.usedAt + 60 * 1000 > now) {
            break;
          }
          var lru_info = this.cache.get(node.value);
          this.unload(lru_info);
        }
        if (info.arr) {
          logger.warn('Receive file.arr at least twice for the same file');
          this.totalSize -= info.arr.length;
        }
        info.arr = file.arr;
        delete file.arr;
        this.totalSize += info.arr.length;
        if (!info.node) {
          logger.debug('LRU: create file_id: ', file.id, ' with arr.length: ', info.arr.length);
          info.node = new src_ListNode(file.id);
        }
        this.lru.onUsed(info.node);
        logger.info('Total file.arr size: ', this.totalSize);
      }
      info.file = file;
      return file;
    }
  }, {
    key: "flushLoad",
    value: function () {
      var _flushLoad = asyncToGenerator_default()(/*#__PURE__*/regenerator_default.a.mark(function _callee5() {
        var pending, idb, transaction_id, read, _iterator, _step, _loop, _t3;
        return regenerator_default.a.wrap(function (_context6) {
          while (1) switch (_context6.prev = _context6.next) {
            case 0:
              pending = this.pending;
              this.pending = [];
              _context6.next = 1;
              return this.idb;
            case 1:
              idb = _context6.sent;
              transaction_id = this.transaction_id++;
              read = idb.transaction(['keyvaluepairs'], 'readonly').objectStore('keyvaluepairs');
              logger.debug('Load group of files from idb', pending.length);
              _iterator = _createForOfIteratorHelper(pending);
              _context6.prev = 2;
              _loop = /*#__PURE__*/regenerator_default.a.mark(function _loop() {
                var query, request;
                return regenerator_default.a.wrap(function (_context5) {
                  while (1) switch (_context5.prev = _context5.next) {
                    case 0:
                      query = _step.value;
                      request = read.get(query.key);
                      request.onsuccess = function (event) {
                        var blob = event.target.result;
                        if (blob) {
                          if (blob.size === 0) {
                            logger.error('Receive empty blob from db ', query.key);
                          }
                          query.resolve({
                            data: blob,
                            transaction_id: transaction_id
                          });
                        } else {
                          query.reject();
                        }
                      };
                      request.onerror = function () {
                        return query.reject(request.error);
                      };
                    case 1:
                    case "end":
                      return _context5.stop();
                  }
                }, _loop);
              });
              _iterator.s();
            case 3:
              if ((_step = _iterator.n()).done) {
                _context6.next = 5;
                break;
              }
              return _context6.delegateYield(_loop(), "t0", 4);
            case 4:
              _context6.next = 3;
              break;
            case 5:
              _context6.next = 7;
              break;
            case 6:
              _context6.prev = 6;
              _t3 = _context6["catch"](2);
              _iterator.e(_t3);
            case 7:
              _context6.prev = 7;
              _iterator.f();
              return _context6.finish(7);
            case 8:
            case "end":
              return _context6.stop();
          }
        }, _callee5, this, [[2, 6, 7, 8]]);
      }));
      function flushLoad() {
        return _flushLoad.apply(this, arguments);
      }
      return flushLoad;
    }()
  }, {
    key: "load",
    value: function load(key, resolve, reject) {
      var _this6 = this;
      if (this.pending.length === 0) {
        setTimeout(function () {
          _this6.flushLoad();
        }, 1);
      }
      this.pending.push({
        key: key,
        resolve: resolve,
        reject: reject
      });
    }
  }, {
    key: "doLoadFull",
    value: function () {
      var _doLoadFull = asyncToGenerator_default()(/*#__PURE__*/regenerator_default.a.mark(function _callee6(info) {
        var _this7 = this;
        var idb_key;
        return regenerator_default.a.wrap(function (_context7) {
          while (1) switch (_context7.prev = _context7.next) {
            case 0:
              if (!info.arr) {
                _context7.next = 1;
                break;
              }
              return _context7.abrupt("return", {
                data: new Blob([info.arr]),
                transaction_id: -1
              });
            case 1:
              if (!info.idb_key) {
                _context7.next = 3;
                break;
              }
              idb_key = info.idb_key; //return this.store.getItem(idb_key);
              _context7.next = 2;
              return new Promise(function (resolve, reject) {
                _this7.load(idb_key, resolve, reject);
              });
            case 2:
              return _context7.abrupt("return", _context7.sent);
            case 3:
              throw new Error('File is not loaded');
            case 4:
            case "end":
              return _context7.stop();
          }
        }, _callee6);
      }));
      function doLoadFull(_x4) {
        return _doLoadFull.apply(this, arguments);
      }
      return doLoadFull;
    }()
  }, {
    key: "doLoad",
    value: function () {
      var _doLoad = asyncToGenerator_default()(/*#__PURE__*/regenerator_default.a.mark(function _callee7(info, offset, size) {
        var count, _res, res, data_size, _t4;
        return regenerator_default.a.wrap(function (_context8) {
          while (1) switch (_context8.prev = _context8.next) {
            case 0:
              if (!(!info.arr && !info.idb_key && info.file.local.path)) {
                _context8.next = 7;
                break;
              }
              _context8.prev = 1;
              _context8.next = 2;
              return this.client.sendInternal({
                '@type': 'getFileDownloadedPrefixSize',
                file_id: info.file.id,
                offset: offset
              });
            case 2:
              count = _context8.sent;
              if (size) {
                _context8.next = 3;
                break;
              }
              size = count.count;
              _context8.next = 4;
              break;
            case 3:
              if (!(size > count.count)) {
                _context8.next = 4;
                break;
              }
              throw new Error('File not loaded yet');
            case 4:
              _context8.next = 5;
              return this.client.sendInternal({
                '@type': 'readFilePart',
                path: info.file.local.path,
                offset: offset,
                count: size
              });
            case 5:
              _res = _context8.sent;
              _res.data = new Blob([_res.data]);
              _res.transaction_id = -2;
              //log.error(res);
              return _context8.abrupt("return", _res);
            case 6:
              _context8.prev = 6;
              _t4 = _context8["catch"](1);
              logger.info('readFilePart failed', info, offset, size, _t4);
            case 7:
              _context8.next = 8;
              return this.doLoadFull(info);
            case 8:
              res = _context8.sent;
              // return slice(size, offset + size)
              data_size = res.data.size;
              if (!size) {
                size = data_size;
              }
              if (offset > data_size) {
                offset = data_size;
              }
              res.data = res.data.slice(offset, offset + size);
              return _context8.abrupt("return", res);
            case 9:
            case "end":
              return _context8.stop();
          }
        }, _callee7, this, [[1, 6]]);
      }));
      function doLoad(_x5, _x6, _x7) {
        return _doLoad.apply(this, arguments);
      }
      return doLoad;
    }()
  }, {
    key: "doDelete",
    value: function doDelete(info) {
      this.unload(info);
      return info.idb_key;
    }
  }, {
    key: "readFile",
    value: function () {
      var _readFile2 = asyncToGenerator_default()(/*#__PURE__*/regenerator_default.a.mark(function _callee8(query) {
        var info, response, _t5;
        return regenerator_default.a.wrap(function (_context9) {
          while (1) switch (_context9.prev = _context9.next) {
            case 0:
              _context9.prev = 0;
              if (this.isInited) {
                _context9.next = 1;
                break;
              }
              throw new Error('FileManager is not inited');
            case 1:
              info = this.cache.get(query.file_id);
              if (info) {
                _context9.next = 2;
                break;
              }
              throw new Error('File is not loaded');
            case 2:
              if (info.node) {
                this.lru.onUsed(info.node);
              }
              query.offset = query.offset || 0;
              query.size = query.count || query.size || 0;
              _context9.next = 3;
              return this.doLoad(info, query.offset, query.size);
            case 3:
              response = _context9.sent;
              return _context9.abrupt("return", {
                '@type': 'filePart',
                '@extra': query['@extra'],
                data: response.data,
                transaction_id: response.transaction_id
              });
            case 4:
              _context9.prev = 4;
              _t5 = _context9["catch"](0);
              return _context9.abrupt("return", {
                '@type': 'error',
                '@extra': query['@extra'],
                code: 400,
                message: _t5
              });
            case 5:
            case "end":
              return _context9.stop();
          }
        }, _callee8, this, [[0, 4]]);
      }));
      function readFile(_x8) {
        return _readFile2.apply(this, arguments);
      }
      return readFile;
    }()
  }, {
    key: "deleteFile",
    value: function deleteFile(query) {
      var res = {
        '@type': 'ok',
        '@extra': query['@extra']
      };
      try {
        if (!this.isInited) {
          throw new Error('FileManager is not inited');
        }
        var info = this.cache.get(query.file_id);
        if (!info) {
          throw new Error('File is not loaded');
        }
        var idb_key = this.doDelete(info);
        if (idb_key) {
          res.idb_key = idb_key;
        }
      } catch (e) {}
      return res;
    }
  }]);
}();
/* harmony default export */ var src = __webpack_exports__["default"] = (src_TdClient);

/***/ })
/******/ ]);
});