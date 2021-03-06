# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"

# Read messages from a mongodb capped collection using a tailable cursor
class LogStash::Inputs::MongoDBCapped < LogStash::Inputs::Base
  config_name "mongodbcapped"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

  # The mongo server to connect to (as a mongodb connection string). The database and collection are optional
  config :server, validate: :string, required: false

  # The collection(s) to tail
  #
  # Collections are specified in the notation "[database/]collection", for example "mydb/capped1" or "capped2".
  # Note that the second form is only allowed if a database is specified in the server param
  config :collections, required: true

  # How long to sleep if the cursor gives us no results, to reduce server load
  config :interval, validate: :number, default: 0.5

  # Preferred behavior if a specified collection is missing
  config :on_missing, validate: ["raise", "retry", "ignore"], default: "raise"

  # Preferred behavior if the server is unavailable
  config :on_server_unavailable, validate: ["raise", "retry"], default: "raise"

  def register
    require "json"
    require "uri"
    require "mongo"
    require "mongo/tailable_cursor"

    # I'd hook it up to Cabin, but Cabin doesn't support the proper api (block-style)
    mongo_logger = Logger.new($stdout)
    mongo_logger.level = Logger::WARN
    @mongo = Mongo::Client.new(@server, logger: mongo_logger, max_pool_size: @collections.size)

    # bootstrap connections to all the collections
    @collections = [*@collections] # treat the connections as an array. Always
    @collections.map! do |collection_string|
      collection, database = collection_string.split("/",2).reverse
      database ||= @mongo.database.name
      [database, collection]
    end

    raise LogStash::ConfigurationError, "must have at least one collection" if @collections.empty?
  end

  def run(queue)
    # track each collection with a thread
    @collections.map do |database, collection|
      Thread.new(queue, database, collection) do |queue, database, collection|
        @logger.info("MongoDB tailable thread starting", database: database, collection: collection)
        thread_run(queue, database, collection)
      end
    end.each do |thread|
      thread.join
    end
  end

  def thread_run(queue, database, collection)
    server_missing = 0
    collection_missing = 0
    while !stop?
      begin
        cursor = rebuild_connection(database, collection)
        cursor.start
        if server_missing > 0
          @logger.info("MongoDB server #{@server} now available")
          server_missing = 0
        end
        if collection_missing > 0
          @logger.info("MongoDB collection #{database}/#{collection} now available")
          collection_missing = 0
        end
        subscribe(queue, cursor, database, collection)
      rescue Mongo::Error::OperationFailure => e
        retry if e.retryable? # given that these are fully recoverable errors, don't fail
        collection_missing = handle_error(e, @on_missing, collection_missing, "MongoDB collection #{database}/#{collection} missing")
        return if collection_missing == 0
      rescue Mongo::Error::NoServerAvailable => e
        server_missing = handle_error(e, @on_server_unavailable, server_missing, "MongoDB server #{@server} unavailable")
      end
    end
  end

  def handle_error(error, policy, counter, message)
    case policy
    when "raise"
      raise error
    when "retry"
      @logger.info("#{message}. Exponential backoff starting from #{@interval}") if counter == 0
      counter += 1
      Stud.stoppable_sleep(@interval * (1.5 ** counter)) { stop? }
    when "ignore"
      counter = 0
    end
    return counter
  end

  def rebuild_connection(database, collection)
    coll = @mongo.use(database)[collection]
    raise "Collection must be capped to tail it" unless coll.capped?
    view = coll.find({}, cursor_type: :tailable).sort("$natural" => 1)
    return Mongo::TailableCursor.new(view)
  end

  def subscribe(queue, cursor, database, collection)
    # subscribe until we're stopped (or the connection craps out)
    while !stop?
      begin
        message = cursor.next
      rescue Mongo::Error::OperationFailure => e
        # this can happen if a query wasn't successful
        retry if e.retryable?
        raise e
      rescue StopIteration
        @logger.info("MongoDB tailable cursor broken", uri: @server, database: database, collection: collection)
        raise Mongo::Error::OperationFailure, "unknown transport error" # magic string that marks it as retryable
      else
        if message
          message_size = message.to_bson.bytesize # inefficient, but we don't get the raw message size from mongo's API client
          message = bson_doc_to_hash(message)
          event = LogStash::Event.new(
            "message" => message,
            "database" => database,
            "collection" => collection,
            "message_size" => message_size
          )
          decorate(event)
          queue << event
        else
          Stud.stoppable_sleep(@interval) { stop? }
        end
      end
    end
  end

  # needed because BSON::Document doesn't have a recursive "as_json" method
  def bson_doc_to_hash(bson_doc)
    result = {}
    bson_doc.each do |key, value|
      case value
      when BSON::Binary, BSON::Code, BSON::CodeWithScope, BSON::MaxKey, BSON::MinKey, BSON::ObjectId, BSON::Timestamp, Regexp
        result[key] = value.as_json
      when Hash
        result[key] = bson_doc_to_hash(value)
      else
        result[key] = value.to_s
      end
    end
    return result
  end
end
