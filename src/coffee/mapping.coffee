_ = require('underscore')._
_s = require 'underscore.string'
CONS = require '../lib/constants'

class Mapping
  constructor: (options = {}) ->
    @types = options.types
    @customerGroups = options.customerGroups
    @categories = options.categories
    @taxes = options.taxes
    @channels = options.channels
    @errors = []

  mapProduct: (raw, productType) ->
    productType or= raw.master[@header.toIndex CONS.HEADER_PRODUCT_TYPE]
    rowIndex = raw.startRow

    product = @mapBaseProduct raw.master, productType, rowIndex
    product.masterVariant = @mapVariant raw.master, 1, productType, rowIndex, product
    for rawVariant, index in raw.variants
      rowIndex += 1
      product.variants.push @mapVariant rawVariant, index + 2, productType, rowIndex, product

    product

  mapBaseProduct: (rawMaster, productType, rowIndex) ->
    product =
      productType:
        typeId: 'product-type'
        id: productType.id
      masterVariant: {}
      variants: []

    if @header.has(CONS.HEADER_ID)
      product.id = rawMaster[@header.toIndex CONS.HEADER_ID]

    product.categories = @mapCategories rawMaster, rowIndex
    tax = @mapTaxCategory rawMaster, rowIndex
    product.taxCategory = tax if tax

    for attribName in CONS.BASE_LOCALIZED_HEADERS
      val = @mapLocalizedAttrib rawMaster, attribName, @header.toLanguageIndex()
      product[attribName] = val if val

    unless product.slug
      product.slug = {}
      product.slug[CONS.DEFAULT_LANGUAGE] = @ensureValidSlug(_s.slugify product.name[CONS.DEFAULT_LANGUAGE])

    product

  # TODO
  # - check min length of 2
  # - check max lenght of 64
  ensureValidSlug: (slug, appendix = '') ->
    @slugs or= []
    currentSlug = "#{slug}#{appendix}"
    unless _.contains(@slugs, currentSlug)
      @slugs.push currentSlug
      return currentSlug
    @ensureValidSlug slug, Math.floor((Math.random() * 89999) + 10001) # five digets

  hasValidValueForHeader: (row, headerName) ->
    return false unless @header.has(headerName)
    @isValidValue(row[@header.toIndex headerName])

  isValidValue: (rawValue) ->
    return _.isString(rawValue) and rawValue.length > 0

  mapCategories: (rawMaster, rowIndex) ->
    categories = []
    return categories unless @hasValidValueForHeader(rawMaster, CONS.HEADER_CATEGORIES)
    rawCategories = rawMaster[@header.toIndex CONS.HEADER_CATEGORIES].split CONS.DELIM_MULTI_VALUE
    for rawCategory in rawCategories
      cat =
        typeId: 'category'
      if _.contains(@categories.duplicateNames, rawCategory)
        @errors.push "[row #{rowIndex}:#{CONS.HEADER_CATEGORIES}] The category '#{rawCategory}' is not unqiue!"
        continue
      if _.has(@categories.name2id, rawCategory)
        cat.id = @categories.name2id[rawCategory]
      else if _.has(@categories.fqName2id, rawCategory)
        cat.id = @categories.fqName2id[rawCategory]

      if cat.id
        categories.push cat
      else
        @errors.push "[row #{rowIndex}:#{CONS.HEADER_CATEGORIES}] Can not find category for '#{rawCategory}'!"

    categories

  mapTaxCategory: (rawMaster, rowIndex) ->
    return unless @hasValidValueForHeader(rawMaster, CONS.HEADER_TAX)
    rawTax = rawMaster[@header.toIndex CONS.HEADER_TAX]
    if _.contains(@taxes.duplicateNames, rawTax)
      @errors.push "[row #{rowIndex}:#{CONS.HEADER_TAX}] The tax category '#{rawTax}' is not unqiue!"
      return
    unless _.has(@taxes.name2id, rawTax)
      @errors.push "[row #{rowIndex}:#{CONS.HEADER_TAX}] The tax category '#{rawTax}' is unknown!"
      return

    tax =
      typeId: 'tax-category'
      id: @taxes.name2id[rawTax]

  mapVariant: (rawVariant, variantId, productType, rowIndex, product) ->
    if variantId > 2
      vId = @mapNumber rawVariant[@header.toIndex CONS.HEADER_VARIANT_ID], CONS.HEADER_VARIANT_ID, rowIndex
      return unless vId
      if vId isnt variantId
        @errors.push "[row #{rowIndex}:#{CONS.HEADER_VARIANT_ID}] The variantId is not in order!\n" +
          "Please ensure it's ordered beginning at 2. (the masterVariant has always variantId 1)."
        return
    variant =
      id: variantId
      attributes: []

    variant.sku = rawVariant[@header.toIndex CONS.HEADER_SKU] if @header.has CONS.HEADER_SKU

    languageHeader2Index = @header._productTypeLanguageIndexes productType
    if productType.attributes
      for attribute in productType.attributes
        attrib = if attribute.attributeConstraint is CONS.ATTRIBUTE_CONSTRAINT_SAME_FOR_ALL and variantId > 1
          _.find product.masterVariant.attributes, (a) ->
            a.name is attribute.name
        else
          @mapAttribute rawVariant, attribute, languageHeader2Index, rowIndex
        variant.attributes.push attrib if attrib

    variant.prices = @mapPrices rawVariant[@header.toIndex CONS.HEADER_PRICES], rowIndex
    variant.images = @mapImages rawVariant, variantId, rowIndex

    variant

  mapAttribute: (rawVariant, attribute, languageHeader2Index, rowIndex) ->
    value = @mapValue rawVariant, attribute, languageHeader2Index, rowIndex
    return unless value
    attribute =
      name: attribute.name
      value: value

  mapValue: (rawVariant, attribute, languageHeader2Index, rowIndex) ->
    switch attribute.type.name
      when CONS.ATTRIBUTE_TYPE_SET then @mapSetAttribute rawVariant[@header.toIndex attribute.name], attribute, languageHeader2Index, rowIndex
      when CONS.ATTRIBUTE_TYPE_LTEXT then @mapLocalizedAttrib rawVariant, attribute.name, languageHeader2Index
      when CONS.ATTRIBUTE_TYPE_NUMBER then @mapNumber rawVariant[@header.toIndex attribute.name], attribute.name, rowIndex
      when CONS.ATTRIBUTE_TYPE_MONEY then @mapMoney rawVariant[@header.toIndex attribute.name], attribute.name
      else rawVariant[@header.toIndex attribute.name] # works for text, enum and lenum

  # We currently only support Set of (l)enum
  mapSetAttribute: (raw, attribute, rowIndex) ->
    return unless @isValidValue(raw)
    rawValues = raw.split CONS.DELIM_MULTI_VALUE
    values = []
    for rawValue in rawValues
      values.push rawValue
    
    values

  mapPrices: (raw, rowIndex) ->
    prices = []
    return prices unless @isValidValue(raw)
    rawPrices = raw.split CONS.DELIM_MULTI_VALUE
    for rawPrice in rawPrices
      matchedPrice = rawPrice.match CONS.REGEX_PRICE
      unless matchedPrice
        @errors.push "[row #{rowIndex}:#{CONS.HEADER_PRICES}] Can not parse price '#{rawPrice}'!"
        continue
      country = matchedPrice[2]
      currencyCode = matchedPrice[3]
      centAmount = matchedPrice[4]
      customerGroupName = matchedPrice[6]
      channelKey = matchedPrice[8]
      price =
        value: @mapMoney "#{currencyCode} #{centAmount}", CONS.HEADER_PRICES, rowIndex
      price.country = country if country
      if customerGroupName
        unless _.has(@customerGroups.name2id, customerGroupName)
          @errors.push "[row #{rowIndex}:#{CONS.HEADER_PRICES}] Can not find customer group '#{customerGroupName}'!"
          return []
        price.customerGroup =
          typeId: 'customer-group'
          id: @customerGroups.name2id[customerGroupName]
      if channelKey
        unless _.has(@channels.key2id, channelKey)
          @errors.push "[row #{rowIndex}:#{CONS.HEADER_PRICES}] Can not find channel with key '#{channelKey}'!"
          return []
        price.channel =
          typeId: 'channel'
          id: @channels.key2id[channelKey]

      prices.push price

    prices

  # EUR 300
  # USD 999
  mapMoney: (rawMoney, attribName, rowIndex) ->
    return unless @isValidValue(rawMoney)
    matchedMoney = rawMoney.match CONS.REGEX_MONEY
    unless matchedMoney
      @errors.push "[row #{rowIndex}:#{attribName}] Can not parse money '#{rawMoney}'!"
      return
    # TODO: check for correct currencyCode
    
    money =
      currencyCode: matchedMoney[1]
      centAmount: parseInt matchedMoney[2]

  mapNumber: (rawNumber, attribName, rowIndex) ->
    return unless @isValidValue(rawNumber)
    matchedNumber = rawNumber.match CONS.REGEX_NUMBER
    unless matchedNumber
      @errors.push "[row #{rowIndex}:#{attribName}] The number '#{rawNumber}' isn't valid!"
      return

    parseInt matchedNumber[0]

  # "a.en,a.de,a.it"
  # "hi,Hallo,ciao"
  # values:
  #   de: 'Hallo'
  #   en: 'hi'
  #   it: 'ciao'
  mapLocalizedAttrib: (row, attribName, langH2i) ->
    values = {}
    if _.has langH2i, attribName
      _.each langH2i[attribName], (index, language) ->
        values[language] = row[index]
    # fall back to non localized column if language columns could not be found
    if _.size(values) is 0
      return unless @header.has(attribName)
      val = row[@header.toIndex attribName]
      values[CONS.DEFAULT_LANGUAGE] = val

    values

  mapImages: (rawVariant, variantId, rowIndex) ->
    images = []
    return images unless @hasValidValueForHeader(rawVariant, CONS.HEADER_IMAGES)
    rawImages = rawVariant[@header.toIndex CONS.HEADER_IMAGES].split CONS.DELIM_MULTI_VALUE
    
    for rawImage in rawImages
      image =
        url: rawImage
        # TODO: get dimensions from CSV - format idea: 200x400;90x90
        dimensions:
          w: 0
          h: 0
        #  label: 'TODO'
      images.push image

    images


module.exports = Mapping
