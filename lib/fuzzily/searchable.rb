require 'fuzzily/trigram'

module Fuzzily
  module Searchable
    # fuzzily_searchable <field> [, <field>...] [, <options>]
    def fuzzily_searchable(*fields)
      options = fields.last.kind_of?(Hash) ? fields.pop : {}

      fields.each do |field|
        make_field_fuzzily_searchable(field, options)
      end
    end

    private

    def make_field_fuzzily_searchable(field, options={})
      class_variable_defined?(:"@@fuzzily_searchable_#{field}") and return

      trigram_class_name     = options.fetch(:class_name, 'Trigram')
      trigram_association    = "trigrams_for_#{field}".to_sym
      update_trigrams_method = "update_fuzzy_#{field}!".to_sym

      supports_bulk_inserts  =
        connection.class.name !~ /sqlite/i ||
        connection.send(:sqlite_version) >= '3.7.11'

      has_many trigram_association,
        :class_name => trigram_class_name,
        :as => :owner,
        :conditions => { :fuzzy_field => field.to_s },
        :dependent => :destroy,
        :autosave => true

      singleton_class.send(:define_method,"find_by_fuzzy_#{field}".to_sym) do |*args|
        case args.size
          when 1 then pattern = args.first ; options = {}
          when 2 then pattern, options = args
          else        raise 'Wrong # of arguments'
        end

        options[:limit] ||= 10

        trigram_class_name.constantize.
          scoped(options).
          for_model(self.name).
          for_field(field.to_s).
          matches_for(pattern)
      end

      singleton_class.send(:define_method,"bulk_update_fuzzy_#{field}".to_sym) do
        trigram_class = trigram_class_name.constantize

        self.scoped(:include => trigram_association).find_in_batches(:batch_size => 100) do |batch|
          inserts = []
          batch.each do |record|
            data = Fuzzily::String.new(record.send(field))
            return if data.blank?
            data.scored_trigrams.each do |trigram, score|
              inserts << sanitize_sql_array(['(?,?,?,?,?)', self.name, record.id, field.to_s, score, trigram])
            end
          end

          # take care of quoting
          c = trigram_class.connection
          insert_sql = %Q{
            INSERT INTO %s (%s, %s, %s, %s, %s)
            VALUES
          } % [
            c.quote_table_name(trigram_class.table_name),
            c.quote_column_name('owner_type'),
            c.quote_column_name('owner_id'),
            c.quote_column_name('fuzzy_field'),
            c.quote_column_name('score'),
            c.quote_column_name('trigram')
          ]

          trigram_class.transaction do
            batch.each { |record| record.send(trigram_association).delete_all }

            if supports_bulk_inserts
              trigram_class.connection.insert(insert_sql + inserts.join(", "))
            else
              inserts.each do |insert|
                trigram_class.connection.insert(insert_sql + insert)
              end
            end
          end
        end
      end

      define_method update_trigrams_method do
        self.send(trigram_association).delete_all
        String.new(self.send(field)).scored_trigrams.each do |trigram, score|
          self.send(trigram_association).create!(:score => score, :trigram => trigram, :owner_type => self.class.name)
        end
      end

      after_save do |record|
        next unless record.send("#{field}_changed?".to_sym)
        record.send(update_trigrams_method)
      end

      class_variable_set(:"@@fuzzily_searchable_#{field}", true)
      self
    end
  end
end
