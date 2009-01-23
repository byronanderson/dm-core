module DataMapper

  # Query class represents a query which will be run against the data-store.
  # Generally Query objects can be found inside Collection objects.
  #
  class Query
    include Extlib::Assertions

    OPTIONS = [
      :reload, :offset, :limit, :order, :add_reversed, :fields, :links, :conditions, :unique
    ]

    attr_reader :repository, :model, *OPTIONS - [ :reload, :unique, :includes ]
    attr_writer :add_reversed
    alias add_reversed? add_reversed

    ##
    # indicates if the result set of the query should replace
    # the cached results already in the Identity Map.
    #
    # With @reload set to true, the query results are used to update/overwrite
    # attributes of objects a previous query already loaded.
    #
    # @return [TrueClass, FalseClass]
    # @api semipublic
    def reload?
      @reload
    end

    ##
    # @return [TrueClass, FalseClass]
    #
    # @api semipublic
    def unique?
      @unique
    end

    ##
    # reverses the sort order
    #
    # @return [DataMapper::Query] new reversed duplicate of itself
    #
    # @api public
    def reverse
      dup.reverse!
    end

    ##
    # reverses the sort order
    #
    # @return [DataMapper::Query] self
    #
    def reverse!
      # reverse the sort order
      update(:order => self.order.map { |o| o.reverse })

      self
    end

    ##
    # updates the query object with additional conditions, ordering, or
    # options
    #
    # @param [DataMapper::Query, Hash] conditions, orders, and other options
    #
    # @return [DataMapper::Query] the receiver
    #
    # @api public
    def update(other)
      assert_kind_of 'other', other, self.class, Hash

      assert_valid_other(other)

      if other.kind_of?(Hash)
        return self if other.empty?
        other = self.class.new(@repository, model, other)
      end

      return self if self == other

      # TODO: update this so if "other" had a value explicitly set
      #       overwrite the attributes in self

      # only overwrite the attributes with non-default values
      @reload       = other.reload?       unless other.reload?       == false
      @unique       = other.unique?       unless other.unique?       == false
      @offset       = other.offset        if other.reload? || other.offset != 0
      @limit        = other.limit         unless other.limit         == nil
      @order        = other.order         unless other.order         == model.default_order
      @add_reversed = other.add_reversed? unless other.add_reversed? == false
      @fields       = other.fields        unless other.fields        == @properties.defaults
      @links        = other.links         unless other.links         == []

      update_conditions(other)

      self
    end

    ##
    # Similar to Query#update, but acts on a duplicate.
    #
    # @param [DataMapper::Query, Hash] other other query to merge with
    # @return [DataMapper::Query] updated duplicate of original query
    # @api public
    def merge(other)
      dup.update(other)
    end

    ##
    # Compares two Query objects by asserting that their conditions, sort
    # ordering, and options are the same
    #
    # @return [TrueClass, FalseClass]
    # @api semipublic
    def ==(other)
      return true if super
      return false unless other.kind_of?(self.class)

      # TODO: add a #hash method, and then use it in the comparison, eg:
      #   return hash == other.hash
      @model        == other.model         &&
      @reload       == other.reload?       &&
      @unique       == other.unique?       &&
      @offset       == other.offset        &&
      @limit        == other.limit         &&
      @order        == other.order         &&  # order is significant, so do not sort this
      @add_reversed == other.add_reversed? &&
      @fields       == other.fields        &&  # TODO: sort this so even if the order is different, it is equal
      @links        == other.links         &&  # TODO: sort this so even if the order is different, it is equal
      @conditions.sort_by { |c| c.at(0).hash + c.at(1).hash + c.at(2).hash } == other.conditions.sort_by { |c| c.at(0).hash + c.at(1).hash + c.at(2).hash }
    end

    alias eql? ==

    # @api private
    def bind_values
      bind_values = []

      conditions.each do |tuple|
        next if tuple.size == 2
        operator, property, bind_value = *tuple

        if :raw == operator
          bind_values.push(*bind_value)
        else
          if bind_value.kind_of?(Range) && bind_value.exclude_end? && (operator == :eql || operator == :not)
            bind_values.push(bind_value.first, bind_value.last)
          else
            bind_values << bind_value
          end
        end
      end

      bind_values
    end

    ##
    # returns the property (if any) used to indicate the class which
    # the results should be instantiated as; the Discriminator property
    # declared on the model
    #
    # @return [DataMapper::Property, NilClass] The Discriminator property
    #   declared on the model
    # @api semipublic
    def inheritance_property
      fields.detect { |property| property.type == DataMapper::Types::Discriminator }
    end

    def inheritance_property_index
      fields.index(inheritance_property)
    end

    ##
    # Get the indices of key properties for this Query's model in its Repository
    #
    # @param [DataMapper::Repository] the repository to act on
    # @api private
    # TODO: spec this
    def key_property_indexes(repository)
      model.key(repository.name).map { |property| fields.index(property) }
    end

    ##
    # find the point in self.conditions where the sub select tuple is
    # located. Delete the tuple and add value.conditions. value must be a
    # <DM::Query>
    #
    # @param [DataMapper::Operator] operator
    #   Identifies the position in +self+ at which the subquery sould be merged
    # @param [DataMapper::Property] property
    #   Identifies the position in +self+ at which the subquery sould be merged
    # @param [DataMapper::Query] value
    #   The query object to merge into +self+
    #
    # @return [Array(Tuple<Query::Operator, Property, Object>)]
    #
    # @api semipublic
    def merge_subquery(operator, property, value)
      assert_kind_of 'value', value, self.class

      new_conditions = []
      conditions.each do |tuple|
        if tuple == [ operator, property, value ]
          value.conditions.each do |subquery_tuple|
            new_conditions << subquery_tuple
          end
        else
          new_conditions << tuple
        end
      end
      @conditions = new_conditions
    end

    def inspect
      attrs = [
        [ :repository, repository.name ],
        [ :model,      model           ],
        [ :fields,     fields          ],
        [ :links,      links           ],
        [ :conditions, conditions      ],
        [ :order,      order           ],
        [ :limit,      limit           ],
        [ :offset,     offset          ],
        [ :reload,     reload?         ],
        [ :unique,     unique?         ],
      ]

      "#<#{self.class.name} #{attrs.map { |(k,v)| "@#{k}=#{v.inspect}" } * ' '}>"
    end

    private

    def initialize(repository, model, options = {})
      assert_kind_of 'repository', repository, Repository
      assert_kind_of 'model',      model,      Model
      assert_kind_of 'options',    options,    Hash

      # XXX: what is the reason for this?
      options.each { |k,v| options[k] = v.call if v.kind_of?(Proc) }

      assert_valid_options(options)

      @repository = repository
      @properties = model.properties(@repository.name)

      @model        = model                               # must be Class that includes DM::Resource
      @reload       = options.fetch :reload,       false  # must be true or false
      @unique       = options.fetch :unique,       false  # must be true or false
      @offset       = options.fetch :offset,       0      # must be an Integer greater than or equal to 0
      @limit        = options.fetch :limit,        nil    # must be an Integer greater than or equal to 1
      @order        = options.fetch :order,        model.default_order(@repository.name)   # must be an Array of Symbol, DM::Query::Direction or DM::Property
      @add_reversed = options.fetch :add_reversed, false  # must be true or false
      @fields       = options.fetch :fields,       @properties.defaults  # must be an Array of Symbol, String or DM::Property
      @links        = options.fetch :links,        []     # must be an Array of Tuples - Tuple [DM::Query,DM::Assoc::Relationship]
      @conditions   = []                                  # must be an Array of triplets (or pairs when passing in raw String queries)

      # XXX: should I validate that each property in @order corresponds
      # to something in @fields?  Many DB engines require they match,
      # and I can think of no valid queries where a field would be so
      # important that you sort on it, but not important enough to
      # return.

      normalize_order
      normalize_fields
      normalize_links

      # treat all non-options as conditions
      (options.keys - OPTIONS).each do |k|
        append_condition(k, options[k])
      end

      # parse raw options[:conditions] differently
      if conditions = options[:conditions]
        if conditions.kind_of?(Hash)
          conditions.each do |k,v|
            append_condition(k, v)
          end
        elsif conditions.kind_of?(Array)
          raw_query, *bind_values = conditions
          @conditions << if bind_values.empty?
            [ :raw, raw_query ]
          else
            [ :raw, raw_query, bind_values ]
          end
        end
      end
    end

    def initialize_copy(original)
      # deep-copy the condition tuples when copying the object
      @conditions = original.conditions.map { |tuple| tuple.dup }
    end

    # validate the options
    # @param [#each] options the options to validate
    # @raise [ArgumentError] if any pairs in +options+ are invalid options
    # @api private
    def assert_valid_options(options)
      # [DB] This might look more ugly now, but it's 2x as fast as the old code
      # [DB] This is one of the heavy spots for Query.new I found during profiling.
      options.each do |attribute, value|
        case attribute
          when :reload, :unique
            if value != true && value != false
              raise ArgumentError, "+options[:#{attribute}]+ must be true or false, but was #{value.inspect}", caller(2)
            end

          when :offset
            assert_kind_of 'options[:offset]', value, Integer

            unless value >= 0
              raise ArgumentError, "+options[:offset]+ must be greater than or equal to 0, but was #{value.inspect}", caller(2)
            end

          when :limit
            assert_kind_of 'options[:limit]', value, Integer

            unless value >= 1
              raise ArgumentError, "+options[:limit]+ must be greater than or equal to 1, but was #{value.inspect}", caller(2)
            end

          when :fields
            assert_kind_of 'options[:fields]', value, Array

            if value.empty? && options[:unique] == false
              raise ArgumentError, '+options[:fields]+ cannot be empty if +options[:unique] is false', caller(2)
            end

          when :order
            assert_kind_of 'options[:order]', value, Array

            if value.empty? && options.key?(:fields) && options[:fields].any? { |p| !p.kind_of?(Operator) }
              raise ArgumentError, '+options[:order]+ cannot be empty if +options[:fields] contains a non-operator', caller(2)
            end

          when :links
            assert_kind_of 'options[:links]', value, Array

            if value.empty?
              raise ArgumentError, '+options[:links]+ cannot be empty', caller(2)
            end

          when :conditions
            assert_kind_of 'options[:conditions]', value, Hash, Array

            if value.empty?
              raise ArgumentError, '+options[:conditions]+ cannot be empty', caller(2)
            end
        end
      end
    end

    # validate other DM::Query or Hash object
    # @param [Object] other object whose validity is under test
    # @raise [ArgumentError]
    #   if +other+ is a DM::Query, but has a different repository or model
    # @api private
    def assert_valid_other(other)
      return unless other.kind_of?(Query)

      unless other.repository == repository
        raise ArgumentError, "+other+ #{self.class} must be for the #{repository.name} repository, not #{other.repository.name}", caller(2)
      end

      unless other.model == model
        raise ArgumentError, "+other+ #{self.class} must be for the #{model.name} model, not #{other.model.name}", caller(2)
      end
    end

    # normalize order elements to DM::Query::Direction
    def normalize_order
      @order.map! do |order|
        case order
          when Direction
            # NOTE: The property is available via order.property
            # TODO: if the Property's model doesn't match
            # self.model, append the property's model to @links
            # eg:
            #if property.model != self.model
            #  @links << discover_path_for_property(property)
            #end

            order
          when Property
            # TODO: if the Property's model doesn't match
            # self.model, append the property's model to @links
            # eg:
            #if property.model != self.model
            #  @links << discover_path_for_property(property)
            #end

            Direction.new(order)
          when Operator
            property = @properties[order.target]
            Direction.new(property, order.operator)
          when Symbol, String
            property = @properties[order]

            if property.nil?
              raise ArgumentError, "+options[:order]+ entry #{order} does not map to a DataMapper::Property", caller(2)
            end

            Direction.new(property)
          else
            raise ArgumentError, "+options[:order]+ entry #{order.inspect} not supported", caller(2)
        end
      end
    end

    # normalize fields to DM::Property
    def normalize_fields
      # TODO: make @fields a PropertySet
      # TODO: raise an exception if the property is not available in the repository
      @fields.map! do |field|
        case field
          when Property, Operator
            # TODO: if the Property's model doesn't match
            # self.model, append the property's model to @links
            # eg:
            #if property.model != self.model
            #  @links << discover_path_for_property(property)
            #end
            field
          when Symbol, String
            property = @properties[field]

            if property.nil?
              raise ArgumentError, "+options[:fields]+ entry #{field} does not map to a DataMapper::Property", caller(2)
            end

            property
          else
            raise ArgumentError, "+options[:fields]+ entry #{field.inspect} not supported", caller(2)
        end
      end
    end

    # normalize links to DM::Query::Path
    def normalize_links
      @links.map! do |link|
        case link
          when Associations::Relationship
            link
          when Symbol, String
            link = link.to_sym

            unless relationship = model.relationships(@repository.name).key?(link)
              raise ArgumentError, "+options[:links]+ entry #{link} does not map to a DataMapper::Associations::Relationship", caller(2)
            end

            relationship
          else
            raise ArgumentError, "+options[:links]+ entry #{link.inspect} not supported", caller(2)
        end
      end
    end

    # validate that all the links are present for the given DM::Query::Path
    #
    def validate_query_path_links(path)
      path.relationships.map do |relationship|
        @links << relationship unless @links.include?(relationship)
      end
    end

    # Append conditions to this Query
    # @param [Symbol, String, Property, Query::Path, Operator] clause
    # @param [Object] bind_value
    # @api private
    def append_condition(clause, bind_value)
      operator = :eql
      bind_value = bind_value.call if bind_value.kind_of?(Proc)

      property = case clause
        when Property
          clause
        when Query::Path
          validate_query_path_links(clause)
          clause
        when Operator
          operator = clause.operator
          return if operator == :not && bind_value == []
          # FIXME: this code duplicates conditions in this method.  Try
          # to refactor out the common code.
          if clause.target.kind_of?(Property)
            clause.target
          elsif clause.target.kind_of?(Query::Path)
            validate_query_path_links(clause.target)
            clause.target
          elsif clause.target.kind_of?(Symbol)
            @properties[clause.target]
          end
        when Symbol
          @properties[clause]
        when String
          if clause =~ /\w\.\w/
            query_path = @model
            clause.split(".").each { |piece| query_path = query_path.send(piece) }
            append_condition(query_path, bind_value)
            return
          else
            @properties[clause]
          end
        else
          raise ArgumentError, "Condition type #{clause.inspect} not supported", caller(2)
      end

      if property.nil?
        raise ArgumentError, "Clause #{clause.inspect} does not map to a DataMapper::Property", caller(2)
      end

      bind_value = dump_custom_value(property, bind_value)

      @conditions << [ operator, property, bind_value ]
    end

    def dump_custom_value(property_or_path, bind_value)
      case property_or_path
        when DataMapper::Query::Path
          dump_custom_value(property_or_path.property, bind_value)
        when Property
          if property_or_path.custom?
            property_or_path.type.dump(bind_value, property_or_path)
          else
            bind_value
          end
        else
          bind_value
      end
    end

    def update_conditions(other)
      @conditions = @conditions.dup

      # build an index of conditions by the property and operator to
      # avoid nested looping
      conditions_index = {}
      @conditions.each do |condition|
        operator, property = *condition
        next if :raw == operator
        conditions_index[property] ||= {}
        conditions_index[property][operator] = condition
      end

      # loop over each of the other's conditions, and overwrite the
      # conditions when in conflict
      other.conditions.each do |other_condition|
        other_operator, other_property, other_bind_value = *other_condition

        unless :raw == other_operator
          conditions_index[other_property] ||= {}
          if condition = conditions_index[other_property][other_operator]
            operator, property, bind_value = *condition

            next if bind_value == other_bind_value

            # overwrite the bind value in the existing condition
            condition[2] = case operator
              when :eql, :like then other_bind_value
              when :gt,  :gte  then [ bind_value, other_bind_value ].min
              when :lt,  :lte  then [ bind_value, other_bind_value ].max
              when :not, :in
                if bind_value.kind_of?(Array)
                  bind_value |= other_bind_value
                elsif other_bind_value.kind_of?(Array)
                  other_bind_value |= bind_value
                else
                  other_bind_value
                end
            end

            next  # process the next other condition
          end
        end

        # otherwise append the other condition
        @conditions << other_condition.dup
      end

      @conditions
    end
  end # class Query
end # module DataMapper

dir = Pathname(__FILE__).dirname.expand_path / 'query'

require dir / 'direction'
require dir / 'operator'
require dir / 'path'
