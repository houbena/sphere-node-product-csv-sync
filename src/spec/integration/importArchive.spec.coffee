Promise = require 'bluebird'
_ = require 'underscore'
archiver = require 'archiver'
_.mixin require('underscore-mixins')
{Import} = require '../../lib/main'
Config = require '../../config'
TestHelpers = require './testhelpers'
Excel = require 'exceljs'
cuid = require 'cuid'
path = require 'path'
tmp = require 'tmp'
fs = Promise.promisifyAll require('fs')
# will clean temporary files even when an uncaught exception occurs
tmp.setGracefulCleanup()

CHANNEL_KEY = 'retailerA'


createImporter = (format) ->
  config = JSON.parse(JSON.stringify(Config)) # cloneDeep
  config.importFormat = format || "csv"
  im = new Import config
  im.matchBy = 'sku'
  im.allowRemovalOfVariants = true
  im.suppressMissingHeaderWarning = true
  im

writeXlsx = (filePath, data) ->
  workbook = new Excel.Workbook()
  workbook.created = new Date()
  worksheet = workbook.addWorksheet('Products')
  console.log "Generating Xlsx file"

  data.forEach (items, index) ->
    if index
      worksheet.addRow items
    else
      headers = []
      for i of items
        headers.push {
          header: items[i]
        }
      worksheet.columns = headers

  workbook.xlsx.writeFile(filePath)

describe 'Import integration test', ->

  beforeEach (done) ->
    jasmine.getEnv().defaultTimeoutInterval = 90000 # 90 sec
    @importer = createImporter()
    @importer.suppressMissingHeaderWarning = true
    @client = @importer.client

    @productType = TestHelpers.mockProductType()

    TestHelpers.setupProductType(@client, @productType)
    .then (result) =>
      @productType = result
      @client.channels.ensure(CHANNEL_KEY, 'InventorySupply')
    .then -> done()
    .catch (err) -> done _.prettify(err.body)
    .done()
  , 120000 # 2min

  describe '#import', ->

    beforeEach ->
      @newProductName = TestHelpers.uniqueId 'name-'
      @newProductSlug = TestHelpers.uniqueId 'slug-'
      @newProductSku = TestHelpers.uniqueId 'sku-'

    it 'should import multiple archived products from CSV', (done) ->
      tempDir = tmp.dirSync({ unsafeCleanup: true })
      archivePath = path.join tempDir.name, 'products.zip'

      csv = [
        """
          productType,name,variantId,slug
          #{@productType.id},#{@newProductName},1,#{@newProductSlug}
          """,
        """
          productType,name,variantId,slug
          #{@productType.id},#{@newProductName+1},1,#{@newProductSlug+1}
          """
      ]

      Promise.map csv, (content, index) ->
        fs.writeFileAsync path.join(tempDir.name, "products-#{index}.csv"), content
      .then ->
        archive = archiver 'zip'
        outputStream = fs.createWriteStream archivePath

        new Promise (resolve, reject) ->
          outputStream.on 'close', () -> resolve()
          archive.on 'error', (err) -> reject(err)
          archive.pipe outputStream

          archive.bulk([
            { expand: true, cwd: tempDir.name, src: ['**'], dest: 'products'}
          ])
          archive.finalize()
      .then =>
        @importer.importManager(archivePath, true)
      .then =>
        @client.productProjections.staged(true)
          .sort("createdAt", "ASC")
          .where("productType(id=\"#{@productType.id}\")").fetch()
      .then (result) =>
        expect(_.size result.body.results).toBe 2

        p = result.body.results[0]
        expect(p.name).toEqual en: @newProductName
        expect(p.slug).toEqual en: @newProductSlug

        p = result.body.results[1]
        expect(p.name).toEqual en: @newProductName+1
        expect(p.slug).toEqual en: @newProductSlug+1

        done()
      .catch (err) -> done _.prettify(err)
      .finally ->
        tempDir.removeCallback()

    it 'should import multiple archived products from XLSX', (done) ->
      importer = createImporter("xlsx")
      tempDir = tmp.dirSync({ unsafeCleanup: true })
      archivePath = path.join tempDir.name, 'products.zip'

      data = [
        [
          ["productType","name","variantId","slug"],
          [@productType.id,@newProductName,1,@newProductSlug]
        ],
        [
          ["productType","name","variantId","slug"],
          [@productType.id,@newProductName+1,1,@newProductSlug+1]
        ]
      ]

      Promise.map data, (content, index) ->
        writeXlsx(path.join(tempDir.name, "products-#{index}.xlsx"), content)
      .then ->
        archive = archiver 'zip'
        outputStream = fs.createWriteStream archivePath

        new Promise (resolve, reject) ->
          outputStream.on 'close', () -> resolve()
          archive.on 'error', (err) -> reject(err)
          archive.pipe outputStream

          archive.bulk([
            { expand: true, cwd: tempDir.name, src: ['**'], dest: 'products'}
          ])
          archive.finalize()
      .then =>
        importer.importManager(archivePath, true)
      .then =>
        @client.productProjections.staged(true)
        .sort("createdAt", "ASC")
        .where("productType(id=\"#{@productType.id}\")").fetch()
      .then (result) =>
        expect(_.size result.body.results).toBe 2

        p = result.body.results[0]
        expect(p.name).toEqual en: @newProductName
        expect(p.slug).toEqual en: @newProductSlug

        p = result.body.results[1]
        expect(p.name).toEqual en: @newProductName+1
        expect(p.slug).toEqual en: @newProductSlug+1

        done()
      .catch (err) -> done _.prettify(err)
      .finally ->
        tempDir.removeCallback()
