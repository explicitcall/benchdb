db = require './benchdb'
a = require 'async'
_ = require 'underscore'
streamEqual = require 'stream-equal'
fs = require 'fs'
path = require 'path'
Tempfile = require 'temporary/lib/file'
Tempdir = require 'temporary/lib/dir'

testdoc = { _id: 'testdoc', testprop: 41 }

steps = (test, testDb) ->
  uploadedFile = null
  downloadedFile = null
  revisionBeforeUpload = null
  a.waterfall [
    _(testDb.exists).bind(testDb),
    ((res, cb) ->
      test.equals res.error, 'not_found', 'db exists test #1 failed'
      test.equals res.reason, 'no_db_file', 'db exists test #2 failed'
      testDb.existsBool cb),
    ((res, cb) ->
      test.ok not res, 'db exists test #3 failed'
      testDb.createItself cb),
    ((res, cb) ->
      test.ok res.ok, 'db created test #1 failed'
      testDb.existsBool cb)
    ((res, cb) ->
      test.ok res, 'db created test #2 failed'
      testDb.retrieveAll cb),
    ((res, cb) ->
      test.equals res.total_rows, 0, 'newly created db row count test failed'
      testDb.create testdoc, cb),
    ((res, cb) ->
      test.ok res.ok, 'document creation test failed'
      test.equals res.id, testdoc._id, "document creation id comparison
        test failed"
      testDb.retrieve testdoc, cb),
    ((res, cb) ->
      test.equals res.testprop, testdoc.testprop, "document creation property comparison
              test failed"
      testDb.modify _(testdoc).extend(testprop: 42, _rev: res._rev), cb)
    ((res, cb) ->
      test.ok res.ok, 'document modification test failed'
      test.ok res.rev?
      revisionBeforeUpload = res.rev
      generateRandomFile cb),
    ((res, cb) ->
      uploadedFile = res
      updatedDoc = _(testdoc).extend(_rev: revisionBeforeUpload)
      testDb.uploadAttachment updatedDoc, res, path.basename(res), cb),
    ((res, cb) ->
      test.ok res.ok
      test.ok res.id?
      test.equals res.id, testdoc._id
      testDb.retrieve testdoc, cb),
    ((res, cb) ->
      test.equals res.testprop, 42, "document modification property comparison
                          test failed"
      dir = (new Tempdir).path
      test.ok res._attachments?
      filename = Object.keys(res._attachments)[0]
      downloadedFile = path.join dir, filename
      testDb.downloadAttachment res, filename, dir, cb),
    ((res, cb) ->
      uploadedStream = fs.createReadStream uploadedFile
      downloadedStream = fs.createReadStream downloadedFile
      streamEqual uploadedStream, downloadedStream, cb),
    ((res, cb) ->
      test.ok res
      fs.unlink uploadedFile
      fs.unlink downloadedFile
      testDb.removeItself cb),
    ((res, cb) ->
      test.ok res.ok, 'db removal test #1 failed'
      testDb.existsBool cb),
    ((res, cb) ->
      test.ok not res, 'db removal test #2 failed'
      cb())], (err) ->
                test.ok not err, 'error absence final callback test failed'
                test.done()

minBytes = 1024 * 1024 * 10
maxBytes = 1024 * 1024 * 100

generateRandomFile = (cb) ->
  file = new Tempfile
  endRandom = _.random minBytes, maxBytes
  devRandom = fs.createReadStream '/dev/random', { start: 0, end: endRandom }
  devRandom.on 'end', -> cb null, file.path
  devRandom.pipe fs.createWriteStream file.path

chars = 'abcdefghijklmnopqrstuvwxyz'
randChar = -> chars[_.random 0, chars.length - 1]

generateDbName = (host, port, endCb) ->
  name = randChar()
  exists = false
  a.whilst (-> exists), ((cb) ->
    testDb = new db host, port, name
    testDb.exists (error, res) ->
      exists = res.db_name is name
      name += randChar()
      cb()), -> endCb name

module.exports =
  testFullUrl: (test) ->
    generateDbName '127.0.0.1', 5984, (dbName) ->
      testDb = new db "http://127.0.0.1:5984/#{ dbName }"
      test.equals testDb.root, "http://127.0.0.1:5984/#{ dbName }/"
      steps test, testDb

  testSplitUrl: (test) ->
    generateDbName '127.0.0.1', 5984, (dbName) ->
      testDb = new db '127.0.0.1', 5984, dbName
      test.equals testDb.root, "http://127.0.0.1:5984/#{ dbName }/"
      steps test, testDb

  testCheckExists: (test) ->
    generateDbName '127.0.0.1', 5984, (dbName) ->
      testDb = new db '127.0.0.1', 5984, dbName
      a.waterfall [
        _(testDb.existsBool).bind(testDb),
        ((res, cb) ->
          test.ok not res, 'generateDbName test failed'
          testDb.checkExists cb),
        _(testDb.existsBool).bind(testDb),
        ((res, cb) ->
          test.ok res, 'checkExists test failed'
          testDb.removeItself cb),
        ((res, cb) ->
          test.ok res.ok, 'checkExists cleanup test #1 failed'
          testDb.existsBool cb),
        ((res, cb) ->
          test.ok not res, 'checkExists cleanup test #2 failed'
          cb())], -> test.done()
