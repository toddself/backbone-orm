util = require 'util'
Backbone = require 'backbone'
_ = require 'underscore'
inflection = require 'inflection'
Queue = require 'queue-async'

Utils = require '../../utils'
adapters = Utils.adapters
One = require './one'

module.exports = class Many
  constructor: (@model_type, @key, options) ->
    @[key] = value for key, value of options
    @ids_accessor = "#{inflection.singularize(@key)}_ids"
    @foreign_key = inflection.foreign_key(@model_type.model_name) unless @foreign_key
    @collection_type = Backbone.Collection unless @collection_type

  initialize: ->
    @reverse_relation = Utils.reverseRelation(@reverse_model_type, @model_type.model_name) if @model_type.model_name
    throw new Error "Both relationship directions cannot embed (#{@model_type.model_name} and #{@reverse_model_type.model_name}). Choose one or the other." if @embed and @reverse_relation and @reverse_relation.embed

    # The reverse of a hasMany relation should be `belongsTo`, not `hasOne`
    throw new Error "The reverse of a hasMany relation should be `belongsTo`, not `hasOne` (#{@model_type.model_name} and #{@reverse_model_type.model_name})." if @reverse_relation.type is 'hasOne'

    if not @reverse_relation
      reverse_schema = @reverse_model_type.schema()
      reverse_key = inflection.underscore(@model_type.model_name)
      reverse_schema.addRelation(@reverse_relation = new One(@reverse_model_type, reverse_key, {type: 'belongsTo', reverse_model_type: @model_type}))

    # check for join table
    if @reverse_relation.type is 'hasMany' and not @join_table
      if @reverse_relation.join_table
        @join_table = @reverse_relation.join_table
      else
        @join_table = Utils.createJoinTableModel(@, @reverse_relation)

  set: (model, key, value, options) ->
    throw new Error "Many::set: Unexpected key #{key}. Expecting: #{@key} or #{@ids_accessor}" unless (key is @key or key is @ids_accessor)
    collection = @_ensureCollection(model)

    value = value.models if value instanceof Backbone.Collection
    throw new Error "HasMany::set: Unexpected type to set #{key}. Expecting array: #{util.inspect(value)}" unless _.isArray(value)

    # save previous
    previous_models = _.clone(collection.models) if @reverse_relation

    # set the collection with found or created models
    collection.reset(models = (collection.get(Utils.dataId(item)) or Utils.createRelated(@reverse_model_type, item) for item in value))
    collection._orm_loaded = @_checkLoaded(model, key)
    return @

  get: (model, key, callback) ->
    throw new Error "Many::get: Unexpected key #{key}. Expecting: #{@key} or #{@ids_accessor}" unless (key is @key or key is @ids_accessor)
    returnValue = =>
      collection = @_ensureCollection(model)
      return if key is @ids_accessor then _.map(collection.models, (related_model) -> related_model.get('id')) else collection

    # asynchronous path, needs load
    is_loaded = @_fetchRelated model, key, (err) =>
      return (if callback then callback(err) else console.log "Many: unhandled error: #{err}. Please supply a callback") if err
      result = returnValue()
      callback(null, if result.models then result.models else result) if callback

    # synchronous path
    result = returnValue()
    callback(null, if result.models then result.models else result) if is_loaded and callback
    return result

  save: (model, key, callback) ->
    # TODO: auto save the reverse 'belongsTo' relations
    return callback() unless @join_table

    collection = @_ensureCollection(model)
    return callback() unless collection._orm_loaded # not loaded

    # TODO: optimize
    query = {$values: @foreign_key}
    query[@foreign_key] = model.attributes.id
    @join_table.cursor(query).toJSON (err, json) =>
      return callback(err) if err

      related_ids = _.map(collection.models, (test) -> test.get('id'))
      changes = _.groupBy(json, (test) -> if _.contains(related_ids, test.id) then 'kept' else 'removed')
      added = if changes.kept then _.difference(related_ids, changes.kept) else related_ids

      queue = new Queue(1) # TODO: parallelism

      # destroy old
      if changes.removed
        for model_json in changes.removed
          # TODO: optimize
          do (model_json) => queue.defer (callback) =>
            # console.log "Destroying join for: #{@model_type.model_name} join: #{util.inspect(model_json)}"
            @join_table.destroy model_json.id, callback

      # create new
      for related_id in added
        do (related_id) => queue.defer (callback) =>
          attributes = {}
          attributes[@foreign_key] = model.attributes.id
          attributes[@reverse_relation.foreign_key] = related_id
          # console.log "Creating join for: #{@model_type.model_name} join: #{util.inspect(attributes)}"
          join = new @join_table(attributes)
          join.save {}, adapters.bbCallback callback

      queue.await callback

  appendJSON: (json, model, key) ->
    return if key is @ids_accessor # only write the relationships

    collection = @_ensureCollection(model)
    json_key = if @embed then key else @ids_accessor
    return json[json_key] = collection.toJSON() if @embed

  # TODO: review for multiple instances, eg. same id
  has: (model, key, item) ->
    collection = @_ensureCollection(model)
    if item instanceof Backbone.Model
      current_related_model = collection.get(Utils.dataId(item))
      throw new Error "Model added twice: #{util.inspect(current_related_model.attributes)}" if current_related_model and current_related_model isnt item
      return !!current_related_model
    else
      return !!collection.get(Utils.dataId(item))

  add: (model, related_model) ->
    collection = @_ensureCollection(model)
    current_related_model = collection.get(related_model.get('id'))
    return if current_related_model is related_model
    throw new Error "Model added twice: #{util.inspect(current_related_model.attributes)}" if current_related_model
    collection.add(related_model)

  remove: (model, related_model) ->
    collection = @_ensureCollection(model)
    current_related_model = collection.get(related_model.get('id'))
    throw new Error "Model removed but still exists: #{util.inspect(current_related_model.attributes)}" if current_related_model and current_related_model isnt related_model
    return unless current_related_model
    collection.remove(related_model.get('id'))

    # TODO: check which objects are already loaded in cache and ignore ids
  batchLoadRelated: (models_json, callback) ->
    query = {}
    query[@foreign_key] = {$in: (json.id for json in models_json)}
    @reverse_model_type.cursor(query).toJSON callback

  _ensureCollection: (model) ->
    return collection if ((collection = model.attributes[@key]) instanceof @collection_type)
    collection = model.attributes[@key] = new @collection_type()
    return collection unless @reverse_relation # no back links

    # TODO: how should destroying the collection work?
    collection._orm_bindings = {}
    collection._orm_bindings.add = (related_model) =>
      if @reverse_relation.add
        @reverse_relation.add(related_model, model)
      else
        related_model.set(@reverse_relation.key, model) unless related_model.attributes[@reverse_relation.key] is model

    collection._orm_bindings.remove = (related_model) =>
      if @reverse_relation.remove
        @reverse_relation.remove(related_model, model)
      else
        related_model.set(@reverse_relation.key, null) unless related_model.attributes[@reverse_relation.key] is null

    collection._orm_bindings.reset = (collection, options) =>
      current_models = collection.models
      previous_models = options.previousModels or []

      changes = _.groupBy(previous_models, (test) -> if !!_.find(current_models, (current_model) -> current_model.get('id') is test.get('id')) then 'kept' else 'removed')
      added = if changes.kept then _.select(current_models, (test) -> !!_.find(changes.kept, (keep_model) -> keep_model.get('id') is test.get('id'))) else current_models

      # update back links
      (collection._orm_bindings.remove(related_model) for related_model in changes.removed) if changes.removed
      (collection._orm_bindings.add(related_model) for related_model in added)

    collection.on(method, collection._orm_bindings[method]) for method in ['add', 'remove', 'reset']
    return collection

  # TODO: optimize so don't need to check each time
  _checkLoaded: (model, key) ->
    collection = @_ensureCollection(model)
    return false for related_model in collection.models when related_model._orm_needs_load
    return true

  _isLoaded: (model, key) ->
    collection = @_ensureCollection(model)
    return false unless collection._orm_loaded
    return @_checkLoaded(model, key)

  # TODO: check which objects are already loaded in cache and ignore ids
  _fetchPlaceholders: (model, key, callback) ->
    if @reverse_relation.type is 'hasMany'
      collection = @_ensureCollection(model)
      return callback(null, collection.models) if collection._orm_loaded

      query = {$values: @reverse_relation.foreign_key}
      query[@foreign_key] = model.attributes.id
      @join_table.cursor(query).toJSON (err, json) =>
        collection._orm_loaded = true
        return callback(err) if err
        for related_id in json
          # skip existing
          continue if related_model = collection.get(related_id)
          collection.add(related_model = Utils.createRelated(@reverse_model_type, related_id))

        callback(null, collection.models)
    else
      @_loadModels(model, key, callback)

  # TODO: optimize so don't need to check each time
  _fetchRelated: (model, key, callback) ->
    return true if @_isLoaded(model, key) # already loaded

    # load placeholders with ids
    @_fetchPlaceholders model, key, (err, related_models) =>
      return callback(err) if err
      return callback(null, []) unless related_models.length # no relations

      return callback(null, related_models) if key is @ids_accessor # ids only, no need to fetch the models
      @_loadModels(model, key, callback)

    return false

  _loadModels: (model, key, callback) ->
    collection = @_ensureCollection(model)

    # TODO: check which objects are already loaded in cache and ignore ids
#    load_ids = []
#    for related_model in collection.models
#      continue unless related_model._orm_needs_load
#      throw new Error "Missing id for load" unless id = related_model.get('id')
#      load_ids.push(id)

    # loaded
#    unless load_ids.length
#      collection._orm_loaded = true
#      return callback(null, collection.models)

    # fetch
    query = {}
    query[@foreign_key] = model.attributes.id
    @reverse_model_type.cursor(query).toJSON (err, json) =>
      return callback(err) if err

      # process the found models
      collection._orm_loaded = true
      for model_json in json

        # update existing
        if related_model = collection.get(model_json.id)
          related_model.set(json)
          delete related_model._orm_needs_load

        # create new
        else
          collection.add(related_model = Utils.createRelated(@reverse_model_type, model_json))

      cache.updateCached(collection.models) if cache = @reverse_model_type.cache()
      callback(null, collection.models)
