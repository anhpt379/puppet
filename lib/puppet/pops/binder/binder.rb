# The Binder is responsible for processing layered bindings that can be used to setup an Injector.
#
# An instance should be created and a call to {#define_layers} should be made which will process the layered bindings
# (handle overrides, abstract entries etc.).
# The constructed hash with `key => InjectorEntry` mappings is obtained as {#injector_entries}, and is used to initialize an
# {Puppet::Pops::Binder::Injector Injector}.
#
# @api public
#
class Puppet::Pops::Binder::Binder

  # @api private
  attr_reader :injector_entries

  # @api private
  attr_reader :key_factory

  # A parent Binder or nil
  # @api private
  attr_reader :parent

  # The next anonymous key to use
  # @api private
  attr_reader :anonymous_key

  # @api public
  def initialize(layered_bindings, parent_binder=nil)
    @parent = parent_binder

    @key_factory = Puppet::Pops::Binder::KeyFactory.new()

    # Resulting hash of all key -> binding
    @injector_entries = {}

    # First anonymous key is the parent's next (non incremented key)
    @anonymous_key = 0 + (@parent.nil? ? 0 : @parent.anonymous_key)
    define_layers(layered_bindings)
  end

  # Binds layers from highest to lowest as defined by the given LayeredBindings.
  # @note
  #   The model should have been
  #   validated to get better error messages if the model is invalid. This implementation expects the model
  #   to be valid, and any errors raised will be more technical runtime errors.
  #
  # @param layered_bindings [Puppet::Pops::Binder::Bindings::LayeredBindings] the named and ordered layers
  # @raise ArgumentError if this binder is already configured
  # @raise ArgumentError if bindings with unresolved 'override' surfaces as an effective binding
  # @raise ArgumentError if the given argument has the wrong type, or if model is invalid in some way
  # @return [Puppet::Pops::Binder::Binder] self
  # @api public
  #
  def define_layers(layered_bindings)

    LayerProcessor.new(self, key_factory).bind(layered_bindings)
    injector_entries.each  do |k,v|
      unless key_factory.is_contributions_key?(k) || v.is_resolved?()
        raise ArgumentError, "Binding with unresolved 'override' detected: #{self.class.format_binding(v.binding)}}"
      end
    end
  end
  private :define_layers

  # @api private
  def next_anonymous_key
    tmp = @anonymous_key
    @anonymous_key += 1
    tmp
  end

  # @api private
  def self.format_binding(b)
    type_name = Puppet::Pops::Types::TypeCalculator.new().string(b.type)
    layer_name, bindings_name = get_named_binding_layer_and_name(b)
    "binding: '#{type_name}/#{b.name}' in: '#{bindings_name}' in layer: '#{layer_name}'"
  end

  # @api private
  def self.format_contribution_source(b) 
    layer_name, bindings_name = get_named_binding_layer_and_name(b)
    "(layer: #{layer_name}, bindings: #{bindings_name})"
  end

  # @api private
  def self.get_named_binding_layer_and_name(b)
    return ['<unknown>', '<unknown>'] if b.nil?
    return [get_named_layer(b), b.name] if b.is_a?(Puppet::Pops::Binder::Bindings::NamedBindings)
    get_named_binding_layer_and_name(b.eContainer)
  end

  # @api private
  def self.get_named_layer(b)
    return '<unknown>' if b.nil?
    return b.name if b.is_a?(Puppet::Pops::Binder::Bindings::NamedLayer)
    get_named_layer(b.eContainer)
  end

  # Processes the information in a layer, aggregating it to the injector_entries hash in its parent binder.
  # A LayerProcessor holds the intermediate state required while processing one layer.
  #
  # @api private
  #
  class LayerProcessor
    attr :bindings
    attr :binder
    attr :key_factory
    attr :contributions

    def initialize(binder, key_factory)
      @binder = binder
      @key_factory = key_factory
      @bindings = []
      @contributions = []
      @@bind_visitor ||= Puppet::Pops::Visitor.new(nil,"bind",0,0)
    end

    # Add the binding to the list of potentially effective bindings from this layer
    # @api private
    #
    def add(b)
      bindings << Puppet::Pops::Binder::InjectorEntry.new(b)
    end

    # Add a multibind contribution
    # @api private
    #
    def add_contribution(b)
      contributions << Puppet::Pops::Binder::InjectorEntry.new(b)
    end

    # Bind given abstract binding
    # @api private
    #
    def bind(binding)
      @@bind_visitor.visit_this(self, binding)
    end

    # @return [Puppet::Pops::Binder::InjectorEntry] the entry with the highest (category) precedence
    # @api private
    def highest(b1, b2)
      if b1.is_abstract? != b2.is_abstract?
        # if one is abstract and the other is not, the non abstract wins
        b1.is_abstract? ? b2 : b1
      else
#      case b1.precedence <=> b2.precedence
#      when 1
#        b1
#      when -1
#        b2
#      when 0

        raise_conflicting_binding(b1, b2)
      end
    end

    # Raises a conflicting bindings error given two InjectorEntry's with same precedence in the same layer
    # (if they are in different layers, something is seriously wrong)
    def raise_conflicting_binding(b1, b2)
      b1_layer_name, b1_bindings_name = Puppet::Pops::Binder::Binder.get_named_binding_layer_and_name(b1.binding)
      b2_layer_name, b2_bindings_name = Puppet::Pops::Binder::Binder.get_named_binding_layer_and_name(b2.binding)

      # The resolution is per layer, and if they differ something is serious wrong as a higher layer
      # overrides a lower; so no such conflict should be possible:
      unless b1_layer_name == b2_layer_name
        raise ArgumentError, [
          'Internal Error: Conflicting binding for',
          "'#{b1.binding.name}'",
          'being resolved across layers',
          "'#{b1_layer_name}' and",
          "'#{b2_layer_name}'"
          ].join(' ')
      end

      # Conflicting bindings made from the same source
      if b1_bindings_name == b2_bindings_name
        raise ArgumentError, [
          'Conflicting binding for name:',
          "'#{b1.binding.name}'",
          'in layer:',
          "'#{b1_layer_name}', ",
          'both from:',
          "'#{b1_bindings_name}'"
          ].join(' ')
      end

      # Conflicting bindings from different sources
      raise ArgumentError, [
        'Conflicting binding for name:',
        "'#{b1.binding.name}'",
        'in layer:',
        "'#{b1_layer_name}',",
        'from:',
        "'#{b1_bindings_name}', and",
        "'#{b2_bindings_name}'"
        ].join(' ')
    end


    # Produces the key for the given Binding.
    # @param binding [Puppet::Pops::Binder::Bindings::Binding] the binding to get a key for
    # @return [Object] an opaque key
    # @api private
    #
    def key(binding)
      k = if is_contribution?(binding)
        # contributions get a unique (sequential) key
        binder.next_anonymous_key()
      else
        key_factory.binding_key(binding)
      end
    end

    # @api private
    def is_contribution?(binding)
      ! binding.multibind_id.nil?
    end

    # @api private
    def bind_Binding(o)
      if is_contribution?(o)
        add_contribution(o)
      else
        add(o)
      end
    end

    # @api private
    def bind_Bindings(o)
      o.bindings.each {|b| bind(b) }
    end

    # @api private
    def bind_NamedBindings(o)
      # Name is ignored here, it should be introspected when needed (in case of errors)
      o.bindings.each {|b| bind(b) }
    end

    # Process layered bindings from highest to lowest layer
    # @api private
    #
    def bind_LayeredBindings(o)
      o.layers.each do |layer|
        processor = LayerProcessor.new(binder, key_factory)
        # All except abstract (==error) are transfered to injector_entries

        processor.bind(layer).each do |k, v|
          entry = binder.injector_entries[k]
          unless key_factory.is_contributions_key?(k)
            if v.is_abstract?()
              layer_name, bindings_name = Puppet::Pops::Binder::Binder.get_named_binding_layer_and_name(v.binding)
              type_name = key_factory.type_calculator.string(v.binding.type)
              raise ArgumentError, "The abstract binding '#{type_name}/#{v.binding.name}' in '#{bindings_name}' in layer '#{layer_name}' was not overridden"
            end
            raise ArgumentError, "Internal Error - redefinition of key: #{k}, (should never happen)" if entry
            binder.injector_entries[k] = v
          else
            entry ? entry << v : binder.injector_entries[k] = v
          end
        end
      end
    end

    # Processes one named ("top level") layer consisting of a list of NamedBindings
    # @api private
    #
    def bind_NamedLayer(o)
      o.bindings.each {|b| bind(b) }
      this_layer = {}

      # process regular bindings
      bindings.each do |b|
        bkey = key(b.binding)

        # ignore if a higher layer defined it, but ensure override gets resolved
        if x = binder.injector_entries[bkey]
          x.mark_override_resolved()
          next
        end

        # if already found in this layer, one wins (and resolves override), or it is an error
        existing = this_layer[bkey]
        # TODO: highest is not really needed - it is an error at all times when there are no categories
        winner = existing ? highest(existing, b) : b
        this_layer[bkey] = winner
        if existing
          winner.mark_override_resolved()
        end
      end

      # Process contributions
      # - organize map multibind_id to bindings with this id
      # - for each id, create an array with the unique anonymous keys to the contributed bindings
      # - bind the index to a special multibind contributions key (these are aggregated)
      #
      c_hash = Hash.new {|hash, key| hash[ key ] = [] }
      contributions.each {|b| c_hash[ b.binding.multibind_id ] << b }
      # - for each id
      c_hash.each do |k, v|
        index = v.collect do |b|
          bkey = key(b.binding)
          this_layer[bkey] = b
          bkey
        end
        contributions_key = key_factory.multibind_contributions(k)
        unless this_layer[contributions_key]
          this_layer[contributions_key] = []
        end
        this_layer[contributions_key] += index
      end
      this_layer
    end
  end
end
