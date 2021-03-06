weak = require 'weak'
docIdOk = require('./common').docIdOk
_ = require 'underscore'
__ = require 'arguejs'
DB = require './api'
async = require 'async'
falafel = require 'falafel'
lang = require 'cssauron-falafel'
url = require 'url'

# FIXME: should also test for WeakMap in browsers
weakOk = _.isFunction(weak) or (_.isObject(weak) and not _.isEmpty(weak))

apiOk = (api) ->
  if not api instanceof DB
    throw 'BenchDB: attempt to create an object with wrong backend'

class Instance
  attemptApiCall = (instance, apiCall, continueOnConflict, cb) ->
    isConflicted = true
    attemptCycle = (whilstCb) ->
      apiCall instance.data, (error, res) ->
        if not error and res.error is 'conflict'
          isConflicted = true
          instance.refresh whilstCb
        else
          isConflicted = false
          whilstCb error, res
    if continueOnConflict
      async.doWhilst attemptCycle, (-> isConflicted), cb
    else
      attemptCycle cb

  constructor: (api, id, @type) ->
    apiOk api
    Object.defineProperty @, 'api', value: api
    if not docIdOk id
      throw 'BenchDB::Instance: attempt to create an instance without id'
    Object.defineProperty @, 'id', value: id
    if not @type instanceof Type
      throw 'BenchDB::Instance: atempt to create an instance with wrong type'
    Object.defineProperty @, 'data',
      set: (newData) =>
        delete newData._id
        delete newData.type
        Object.defineProperty newData, '_id', { value: id, enumerable: true }
        Object.defineProperty newData, 'type',
          { value: @type.name, enumerable: true }
        @__data = newData
      get: => @__data
    @data = {}

  refresh: (cb) ->
    @api.retrieve @id, (error, res) =>
      if not error
        @data = res
      cb error, res

  save: ->
    { continueOnConflict, cb } =
      __ continueOnConflict: [Boolean, false], cb: Function
    @api.existsBool @id, (error, res) =>
      if error?
        cb error, res
      else if res
        attemptApiCall @, _(@api.modify).bind(@api), continueOnConflict, cb
      else
        @api.create @data, cb

  remove: ->
    { continueOnConflict, cb } =
      __ continueOnConflict: [Boolean, false], cb: Function
    if @data._rev
      attemptApiCall @, _(@api.remove).bind(@api), continueOnConflict, cb
    else
      cb "attempt to remove a document when it doesn't have a revision", null

class Type
  constructor: (api, name) ->
    if not _.isString(name) or name.length < 1
      throw 'BenchDB::Type: atempt to create a type without a name'
    Object.defineProperty @, 'name', value: name
    apiOk api
    Object.defineProperty @, 'api', value: api
    if not weakOk
      Object.defineProperty @, 'cache', value: {}
    else
      @cache = {}

  instance: ->
    { isSingleton, id, cb } = __
      isSingleton: Boolean, id: [String], cb: Function
    cacheAndCallback = =>
      if isSingleton and weakOk
        strong = @cache[id] and weak.get(@cache[id])
        if not _.isEmpty(strong) and strong instanceof Instance
          cb null, strong
        else
          strong = new Instance @api, id, @
          @cache[id] = weak strong
          cb null, strong
      else
        cb null, (new Instance @api, id, @)
    if id?
      cacheAndCallback()
    else
      @api.uuids (err, res) ->
        if err?
          cb err, res
        else if _.isArray res
          id = res[0]
          cacheAndCallback()
        else
          throw 'BenchDB::Type.instance: inconsistent behavior of @api.uuids'

  all: (cb) -> @filterByField cb

  prepareView: ->
    { viewOpts, viewName, mapSource, reduceSource, cb } =
      __
        viewOpts: [Object, designDocument: '_benchdb_user_views']
        viewName: String
        mapSource: [String]
        reduceSource: [String]
        cb: Function

    docId = "_design/#{ viewOpts.designDocument }"

    @api.retrieve docId, (err, res) =>
      if err?
        cb err, res
        return
      if res.error is 'not_found'
        res = _id: docId, language: 'javascript', views: {}
        res.views[viewName] = {}
      if not _.isObject(res.views[viewName]) or
      res.views[viewName].map isnt mapSource or
      res.views[viewName].reduce isnt reduceSource
        res.views[viewName] =
          map: mapSource
          reduce: reduceSource
        @api.modify res, (err, errRes) ->
          if err?
            cb err, errRes
          else
            cb null
      else
        cb null

  # filter view source which will have filterObject substituted with falafel
  # before saving view source to the DB
  filterSource = (doc) ->
    filterObject = {}

    if doc.type isnt filterObject.type
      return

    result = true

    fields = []
    for filterField, filterValue of filterObject
      if (filterValue is null and doc[filterField] is undefined) or
      (filterValue isnt null and doc[filterField] isnt filterValue)
        result = false
        break
      if filterField isnt 'type'
        fields.push filterField

    if result
      emit(doc[field] for field in fields)

  filterByFields: ->
    { viewOpts, filter, cb } =
      __
        viewOpts: [Object, {}]
        filter: [Object, {}]
        cb: Function

    filterObject = type: @name
    for k, v of filter
      filterObject[k] = null
    values = _.values(filter)
    fields = _.keys(filter)

    if _.isArray viewOpts.sort
      for f in viewOpts.sort
        filterObject[f] = null
      if values.length > 0
        viewOpts.startkey = values
        viewOpts.endkey = values.concat [{}]
        if viewOpts.descending is true
          [viewOpts.startkey, viewOpts.endkey] =
            [viewOpts.endkey, viewOpts.startkey]
        delete viewOpts.key
      else
        for f in ['startkey', 'endkey']
          if viewOpts[f]? and not _.isArray viewOpts[f]
            viewOpts[f] = [viewOpts[f]]
    else
      viewOpts.sort = []
      if values.length > 0
        viewOpts.key = values

    # for some reason esprima doesn't parse any stray function expressions
    # so we should transform filterSource to a variable assignment
    mapSource = (falafel ('var f = ' + filterSource + ''), (node) ->
      if lang('assign')(node) and node.left.name is 'filterObject'
        node.update "filterObject = #{ JSON.stringify filterObject }"
      # ...and then back to function expression
      else if lang('variable-decl')(node) and
      node.declarations[0].id.name is 'f'
        node.update node.declarations[0].init.source()).toString()

    viewName = "#{@name}_#{fields.join ''}_#{viewOpts.sort.join ''}"

    @prepareView { designDocument: '_benchdb' }, viewName, mapSource,
      (err, res) =>
        if err?
          cb err, res
          return
        stringifiedFields = ['key', 'keys', 'startkey', 'endkey']
        for k, v of viewOpts
          if (k in stringifiedFields) or _.isBoolean v
            viewOpts[k] = JSON.stringify v
        delete viewOpts.sort
        query = url.format query: viewOpts
        @api.retrieve "_design/_benchdb/_view/#{viewName}#{query}", (err, res) =>
          if err?
            cb err, res
          else if res.rows?
            iterator = (row, next) =>
              @instance true, row.id, (err, nstnc) ->
                if viewOpts.include_docs? and viewOpts.include_docs is 'true'
                  _(nstnc.data).extend row.doc
                next err, nstnc
            async.map (row for row in res.rows), iterator, (err, results) ->
              cb err,
                total: res.total_rows
                offset: res.offset
                instances: results
          else
            cb 'malformed view results', res

  filterByField: ->
    { viewOpts, field, value, cb } =
      __
        viewOpts: [Object, {}]
        field: [String]
        value: [undefined]
        cb: Function

    filter = {}
    if _.isString(field) and field.length > 0
      if value?
        filter[field] = value
      else
        if _.isArray viewOpts.sort
          viewOpts.sort.push field
        else
          viewOpts.sort = [field]

    @filterByFields viewOpts, filter, cb

module.exports = Type
