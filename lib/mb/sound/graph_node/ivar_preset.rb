module MB
  module Sound
    module GraphNode
      # Gives every graph node class one instance variable layout (Ruby
      # object shape), so Ruby never warns that a class "reached 8 shape
      # variations" (and never falls back to its slower hash-backed objects
      # for that class).
      #
      # Ruby lays out an object's instance variables in the order they are
      # first set.  GraphNode's modules (naming, recipes, routing, the plan
      # layer) set theirs lazily, whenever a node is first named, recorded,
      # branched, or planned, so the same class grew a different layout for
      # each order of those events.  Modules declare those variables here
      # (.declare), and every class that includes GraphNode (directly or
      # through another module) gets Init prepended, which sets each declared
      # variable of the class's modules to nil before the class's own
      # #initialize runs.  Variables a subclass already set before calling
      # super are left alone.
      #
      # Class-specific state that is set after construction goes in the
      # class's own #initialize (as nil) instead.
      module IvarPreset
        @declared = {}
        @cache = {}

        class << self
          # Declares +ivars+ (Symbols like :@graph_node_name) as set lazily by
          # +mod+ (a module that graph node classes include).
          def declare(mod, *ivars)
            (@declared[mod] ||= []).concat(ivars).uniq!
            @cache = {}
          end

          # The declared variables of +klass+'s modules, in a fixed order
          # (outermost ancestor first).
          def ivars_for(klass)
            @cache[klass] ||= klass.ancestors.reverse.flat_map { |a| @declared[a] || [] }.uniq.freeze
          end

          # Sets every declared variable of +obj+'s class that isn't set yet
          # to nil.
          def preset(obj)
            ivars_for(obj.class).each do |iv|
              obj.instance_variable_set(iv, nil) unless obj.instance_variable_defined?(iv)
            end
          end

          # Prepends Init to +base+ if it's a class, or arranges for classes
          # that include +base+ (a module) to get it.
          def attach(base)
            if base.is_a?(Class)
              base.prepend(Init) unless base.ancestors.include?(Init)
            elsif !base.singleton_class.ancestors.include?(Hook)
              base.singleton_class.prepend(Hook)
            end
          end
        end

        # Prepended to graph node classes (see IvarPreset).
        module Init
          def initialize(...)
            IvarPreset.preset(self)
            super
          end
        end

        # Prepended to the singleton class of GraphNode and of modules that
        # include it.
        module Hook
          def included(base)
            super
            IvarPreset.attach(base)
          end
        end
      end
    end
  end
end
