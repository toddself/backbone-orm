util = require 'util'
_ = require 'underscore'
Backbone = require 'backbone'
inflection = require 'inflection'

Utils = require '../../utils'

module.exports = class One
  constructor: (@model_type, @key, options) ->
    @[key] = value for key, value of options
    @ids_accessor = "#{@key}_id"
    @foreign_key = inflection.foreign_key(if @type is 'belongsTo' then @key else @model_type.model_name) unless @foreign_key

  initialize: ->
    @reverse_relation = Utils.reverseRelation(@reverse_model_type, @model_type.model_name) if @model_type.model_name

  set: (model, key, value, options, _set) ->
    # TODO: Allow sql to sync...make a notification? use Backbone.Events?
    key = @key if key is @ids_accessor

    throw new Error "HasOne::set: Unexpected key #{key}. Expecting: #{@key}" unless key is @key
    return @ if @has(model, key, value) # already set

    # clear reverse
    if @reverse_relation
      if @has(model, key, value) and (related_model = model.attributes[@key])
        if @reverse_relation.remove
          @reverse_relation.remove(related_model, model)
        else
          related_model.set(@reverse_relation.key, null)

    related_model = if value then Utils.createRelated(@reverse_model_type, value) else null

    # TODO: Allow sql to sync...make a notification? use Backbone.Events?
    # _set.call(model, @foreign_key, related_model.attributes.id, options) if @type is 'belongsTo'
    # _set.call(related_model, @foreign_key, model.attributes.id, options) if @type is 'hasOne'

    _set.call(model, key, related_model, options)
    return @ if not related_model or not @reverse_relation

    if @reverse_relation.add
      @reverse_relation.add(related_model, model)
    else
      related_model.set(@reverse_relation.key, model)

    return @

  get: (model, key, callback, _get) ->
    if key is @ids_accessor
      related_id = if related_model = model.attributes[@key] then related_model.get('id') else null
      callback(null, related_id) if callback
      return related_id
    else
      throw new Error "HasOne::get: Unexpected key #{key}. Expecting: #{@key}" unless key is @key
      if value = model.attributes[key]

        # needs load
        if value._orm_needs_load
          throw new Error "Missing id for load" unless id = value.get('id')
          @reverse_model_type.cursor(id).toJSON (err, json) =>
            return callback(err) if err
            return callback(new Error "Model not found. Id #{id}") if not json

            # update
            delete value._orm_needs_load
            value.set(key, json)
            @reverse_model_type._cache.markLoaded(value) if @reverse_model_type._cache
            callback(null, value)
          return

      callback(null, value) if callback
      return value

  appendJSON: (json, model, key) ->
    return if key is @ids_accessor # only write the relationships

    return json[@foreign_key] = null unless related_model = model.attributes[key]
    return json[@foreign_key] = if @embed then related_model.toJSON() else related_model.get('id')

  has: (model, key, item) ->
    current_related_model = model.attributes[@key]
    return false if (current_related_model and not item) or (not current_related_model and item)

    # compare ids
    current_id = current_related_model.get('id')
    return current_id is item.get('id') if item instanceof Backbone.Model
    return current_id is item.id if _.isObject(item)
    return current_id is item
