require 'dm-core'
require 'gdata'
require 'nokogiri'
require 'builder'

module DataMapper
  class Property
    OPTIONS << :xml
  end
end

module GoogleBase
  class Adapter < DataMapper::Adapters::AbstractAdapter

    XML_ATTRIBUTES = {
      :xmlns => 'http://www.w3.org/2005/Atom',
      'xmlns:g' => 'http://base.google.com/ns/1.0',
      'xmlns:gd' => 'http://schemas.google.com/g/2005'
    }

    attr_reader :gb
    attr_accessor :dry_run

    def read(query)
      records = []

      operands = query.conditions.operands

      if read_one?(operands)

        response = @gb.get(operands.first.value)
        xml = Nokogiri::XML.parse(response.body)

        each_record(xml, query.fields) do |record|
          records << record
        end

      elsif read_all?(operands)

        start    = query.offset + 1
        per_page = query.limit || 250

        url = "http://www.google.com/base/feeds/items?start-index=#{start}&max-results=#{per_page}"

        while url
          response = @gb.get(url)
          xml = Nokogiri::XML.parse(response.body).at('./xmlns:feed')

          each_record(xml, query.fields) do |record|
            records << record
          end

          break if query.limit && query.limit >= records.length
          url = xml.at("./xmlns:link[@rel='next']/@href")
        end

      else
        raise NotImplementedError
        # TODO implement query conditions
      end

      records
    end

    def create(resources)
      result = 0

      resources.each do |resource|
        xml = build_xml(resource)
        url = "http://www.google.com/base/feeds/items"
        url << "?dry-run=true" if @dry_run

        response = @gb.post(url, xml)

        result += 1 if response.status_code == 201
      end

      result
    end

    def update(attributes, resources)
      result = 0

      resources.each do |resource|
        xml = build_xml(resource)
        url = resource.key.first
        url << "?dry-run=true" if @dry_run

        response = @gb.put(url, xml)

        result += 1 if response.status_code == 200
      end

      result
    end

    def token
      @gb.auth_handler.token
    end

    def build_xml(resource)
      result = ""

      xml = Builder::XmlMarkup.new(:target => result, :indent => 2)
      xml.instruct!

      xml.entry(XML_ATTRIBUTES) do
        resource.model.properties.each do |property|
          value = property.get(resource)
          if custom = property.options[:xml]
            custom.call(xml, value)
          elsif not property.options.has_key?(:xml)
            xml.tag! property.name, value
          end
        end
      end

      result
    end

    private

    def initialize(name, options)
      super(name, options)

      assert_kind_of 'options[:user]',     options[:user],     String
      assert_kind_of 'options[:password]', options[:password], String

      @gb = GData::Client::GBase.new
      @gb.source = 'dm-googlebase'
      @gb.clientlogin(options[:user], options[:password])
      @dry_run = options[:dry_run] || false
    end

    def each_record(xml, fields)
      xml.xpath('./xmlns:entry').each do |entry|
        record = fields.map do |property|
          value = property.typecast(entry.at("./#{property.field}").to_s)

          [ property.field, value ]
        end

        yield record.to_hash
      end
    end

    def read_one?(operands)
      operands.length == 1 &&
      operands.first.kind_of?(DataMapper::Query::Conditions::EqualToComparison) &&
      operands.first.subject.key?
    end

    def read_all?(operands)
      operands.empty?
    end

  end
end

DataMapper::Adapters::GoogleBaseAdapter = GoogleBase::Adapter
