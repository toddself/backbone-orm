// Generated by CoffeeScript 1.6.3
/*
  backbone-orm.js 0.5.0
  Copyright (c) 2013 Vidigami - https://github.com/vidigami/backbone-orm
  License: MIT (http://www.opensource.org/licenses/mit-license.php)
  Dependencies: Backbone.js, Underscore.js, Moment.js, and Inflection.js.
*/


(function() {
  var CacheCursor, _, _ref,
    __hasProp = {}.hasOwnProperty,
    __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

  _ = require('underscore');

  module.exports = CacheCursor = (function(_super) {
    __extends(CacheCursor, _super);

    function CacheCursor() {
      _ref = CacheCursor.__super__.constructor.apply(this, arguments);
      return _ref;
    }

    CacheCursor.prototype.toJSON = function(callback) {
      return this.wrapped_sync_fn('cursor', _.extend({}, this._find, this._cursor)).toJSON(callback);
    };

    return CacheCursor;

  })(require('../cursor'));

}).call(this);
