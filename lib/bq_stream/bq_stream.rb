# require 'bq_stream/config'

module BqStream
  extend Configuration

  define_setting :client_id
  define_setting :service_email
  define_setting :key
  define_setting :project_id
  define_setting :dataset
  define_setting :queued_items_table_name, 'queued_items'
  define_setting :oldest_record_table_name, 'oldest_records'
  define_setting :bq_table_name, 'bq_datastream'
  define_setting :back_date, nil
  define_setting :batch_size, 1000

  def self.log
    @log ||= Logger.new(Rails.root.join('log/bq_stream.log').to_s,
                        File::WRONLY | File::APPEND)
  end

  def self.attr_log
    @log ||= Logger.new(Rails.root.join('log/bq_stream_attributes.log').to_s,
                        File::WRONLY | File::APPEND)
  end

  def self.create_bq_writer
    opts = {}
    opts['client_id']     = client_id
    opts['service_email'] = service_email
    opts['key']           = key
    opts['project_id']    = project_id
    opts['dataset']       = dataset
    @bq_writer = BigQuery::Client.new(opts)
  end

  def self.config_initialized
    QueuedItem.build_table
    OldestRecord.build_table
    create_bq_writer
    create_bq_dataset unless @bq_writer.datasets_formatted.include?(dataset)
    create_bq_table unless @bq_writer.tables_formatted.include?(bq_table_name)
    initialize_old_records
  end

  def self.initialize_old_records
    old_records = @bq_writer.query('SELECT table_name, attr, min(updated_at) '\
                                   'as bq_earliest_update FROM '\
                                   "[#{ENV['PROJECT_ID']}:#{ENV['DATASET']}."\
                                   "#{bq_table_name}] GROUP BY table_name, attr")
    old_records['rows'].each do |r|
      OldestRecord.create(table_name: r['f'][0]['v'],
                          attr: r['f'][1]['v'],
                          bq_earliest_update: Time.at(r['f'][2]['v'].to_f))
    end if old_records['rows']
  end

  def self.available_rows
    available = batch_size - QueuedItem.all.count
    available > 0 ? available : 0
  end

  def self.encode_value(value)
    value.encode('utf-8', invalid: :replace,
                          undef: :replace, replace: '_') rescue nil
  end

  def self.dequeue_items
    operation = (0...5).map { ('a'..'z').to_a[rand(26)] }.join
    log.info "#{Time.now}: [Oldest Record (#{available_rows})] Starting..."
    OldestRecord.update_bq_earliest do |oldest_record, r|
      QueuedItem.create(table_name: oldest_record.table_name,
                        record_id: r.id,
                        attr: oldest_record.attr,
                        new_value: r[oldest_record.attr],
                        updated_at: r.updated_at)
    end if available_rows > 0
    log.info "#{Time.now}: [Oldest Record (#{available_rows})] Completed"
    log.info "#{Time.now}: [dequeue_items #{operation}] Starting..."
    create_bq_writer
    records = BqStream::QueuedItem.all.limit(BqStream.batch_size)
x    data = records.collect do |i|
      { table_name: i.table_name, record_id: i.record_id, attr: i.attr,
        updated_at: i.updated_at, new_value: i.new_value }
    end
    @bq_writer.insert(bq_table_name, data)
    records.each(&:destroy)
    log.info "#{Time.now}: [dequeue_items #{operation}] Completed."
  end

  def self.create_bq_dataset
    @bq_writer.create_dataset(dataset)
  end

  def self.create_bq_table
    bq_table_schema = { table_name:   { type: 'STRING', mode: 'REQUIRED' },
                        record_id:    { type: 'INTEGER', mode: 'REQUIRED' },
                        attr:         { type: 'STRING', mode: 'NULLABLE' },
                        new_value:    { type: 'STRING', mode: 'NULLABLE' },
                        updated_at:   { type: 'TIMESTAMP', mode: 'REQUIRED' } }
    @bq_writer.create_table(bq_table_name, bq_table_schema)
  end
end
