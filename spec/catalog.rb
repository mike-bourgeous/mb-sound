# The library catalog (catalog-1, 2026-11-04): design/catalog.md, imported
# by CLAUDE.md, lists every public GraphNode DSL method on one line (its
# signature and the first sentence of its doc comment, grouped by purpose)
# and every console help topic on one line (its title and the commands and
# DSL names it covers), so every session sees the library's breadth before
# writing a sound path ("How we build").
#
# `rake docs:index` writes it beside the notes index (spec/docs_index.rb);
# spec/catalog_spec.rb fails while it is stale, while a DSL method has no
# group in GROUPS, a description, or a short enough one, and while the file
# is over BUDGET.  Descriptions come from the code's doc comments (a first
# sentence over DESCRIPTION_MAX loses its parentheticals); fix a description
# by editing the comment's first sentence (help listings show it too).  Unlike
# DocsIndex this loads mb-sound (the DSL is read from the loaded modules).
module Catalog
  ROOT = File.expand_path('..', __dir__)
  PATH = File.join(ROOT, 'design/catalog.md')

  # Bytes for the whole file (it loads into every session with CLAUDE.md;
  # 15.8 KB, about 4,000 tokens, at its start in catalog-1)
  BUDGET = 17_000

  # Characters for a description, and bytes for a whole line
  DESCRIPTION_MAX = 80
  LINE_MAX = 170

  # Keyword arguments shown in a signature before "..."
  KEYWORDS_SHOWN = 2

  # Commands and DSL names shown on a help topic's line before "..."
  TOPIC_NAMES_SHOWN = 14

  # The DSL's purpose groups in reading order; every public method of the
  # GraphNode *Methods modules is in exactly one (by its primary name;
  # aliases are folded into its line), in the order listed.
  GROUPS = {
    'Synthesis and oscillators' => %i[tone freq phase_table wavetable waveshape ping resonate adsr],
    'Arithmetic and math' => %i[+ - * / ** coerce at abs aabs real imag arg floor ceil round log log2 log10 ring],
    'Filters and EQ' => %i[filter lp4 diode formant peq peq_series bandpass_series hilbert_iir clip_rate inertia smooth],
    'Distortion and shaping' => %i[softclip asoftclip clip aclip quantize aquantize decimate ease aease shape_db ashape_db sample_hold],
    'Delays, reverb, chorus, feedback' => %i[delay feedback_delay multitap haas ping_pong tape_echo reverb chorus feedback],
    'Dynamics, loudness, mastering' => %i[compress compand expand noise_gate limit duck squeeze bands mono_below ride master loudness_meter],
    'Channels, panning, blending' => %i[pan balance place stereo mono left right swap mid_side from_mid_side width matrix blend],
    'Time, length, and units' => %i[until and_then ringdown sounding seconds samples cycles radians],
    'Rates, rendering, and debugging' => %i[oversample resample bounce spy clear_spies debug],
    'Plumbing' => %i[tee get_sampler proc with_buffer as_input multi_sample],
  }.freeze

  # Methods defined by metaprogramming (so with no doc comment of their
  # own), described by the method they forward to.
  DELEGATES = {
    'ChannelMethods defines these with define_method, forwarding to Channels' =>
      %i[left right swap mid_side from_mid_side width balance].to_h { |n| [n, 'MB::Sound::GraphNode::Channels'] },
  }.freeze

  # Modules on every node whose methods are listed by name only, one line
  # per label (graph inspection and saving, not signal processing; these
  # lines are exempt from LINE_MAX).
  NAMES_ONLY = {
    'Naming, printing, saving' => %w[MB::Sound::GraphNode::Nameable MB::Sound::GraphNode::Recipe::ToRuby MB::Sound::GraphNode::Inspect],
    'Graph inspection' => %w[MB::Sound::GraphNode::Traversable],
  }.freeze

  # One DSL method: +names+ is the primary name then its aliases
  Line = Struct.new(:names, :owner, :unbound, :group, keyword_init: true) do
    def name = names.first
  end

  module_function

  def load_library
    require 'mb/sound'
    require 'mb/sound/help'
  end

  # The GraphNode *Methods modules, in inclusion order: only those defined
  # under their names, so a spec's anonymous module named like one (e.g.
  # channel_dispatch_spec's SpecExampleMethods, included for the rest of
  # the process) stays out
  def dsl_modules
    load_library
    MB::Sound::GraphNode.included_modules
      .select { |m| m.name&.start_with?('MB::Sound::GraphNode::') && m.name.end_with?('Methods') }
      .select { |m| (Object.const_get(m.name) rescue nil).equal?(m) }
      .reverse
  end

  def delegates
    DELEGATES.values.reduce({}, :merge)
  end

  # Every public DSL method as a Line (primary names; aliases folded in)
  def dsl_lines
    group_of = GROUPS.flat_map { |g, names| names.map { |n| [n, g] } }.to_h
    dsl_modules.flat_map { |mod|
      names = mod.public_instance_methods(false)
      names.filter_map { |n|
        um = mod.instance_method(n)
        next if um.original_name != n

        aliases = names.select { |a| a != n && mod.instance_method(a).original_name == n }.sort
        if (target = delegates[n])
          um = MB::Sound::Help::DocIndex.unwrap(Object.const_get(target).instance_method(n))
        end
        Line.new(names: [n, *aliases], owner: mod, unbound: um, group: group_of[n])
      }
    }
  end

  # The doc comment's first sentence, +arg+ markers dropped, and
  # parentheticals too when it is longer than DESCRIPTION_MAX.
  def description(unbound)
    comment = begin
      unbound.comment.lines.map { |l| l.sub(/^\s*# ?/, '') }.join
    rescue MethodSource::SourceNotFoundError, NoMethodError
      ''
    end
    s = comment.split(/\n\s*\n/).first.to_s.gsub(/\s+/, ' ').strip
    s = s.split(/(?<=[\w)`'+])(?<!e\.g)(?<!i\.e)\.(\s|$)/).first.to_s
    s = s.gsub(/\+(:?\w+:?)\+/, '\1').gsub('MB::Sound::', '')
    return s if s.length <= DESCRIPTION_MAX

    1 while s.gsub!(/\s*\([^()]*\)/, '')
    s.gsub(/\s+/, ' ').strip
  end

  # `name(a, b, key:, ..., &block)`: positional parameters, required
  # keywords, the first KEYWORDS_SHOWN optional ones, and a block
  def signature(line)
    shown = 0
    more = false
    block = false
    params = line.unbound.parameters.filter_map { |type, n|
      case type
      when :req, :opt then n.to_s
      when :rest then "*#{n}"
      when :keyreq then "#{n}:"
      when :key
        (shown += 1) <= KEYWORDS_SHOWN ? "#{n}:" : (more = true) && nil
      when :keyrest then (more = true) && nil
      when :block then (block = true) && nil
      end
    }
    params << '...' if more
    params << '&block' if block
    names = line.names.join('/')
    params.empty? ? names : "#{names}(#{params.join(', ')})"
  end

  def dsl_section
    lines = dsl_lines.group_by(&:group)
    out = +"## GraphNode DSL\n\n"
    out << "Methods of every node (`node.lp4(800)`; `lib/mb/sound/graph_node/*_methods.rb`); `help :name` shows one's page.\n"
    GROUPS.each do |group, names|
      out << "\n### #{group}\n\n"
      by_name = (lines[group] || []).to_h { |l| [l.name, l] }
      names.each do |n|
        l = by_name[n] or next
        out << "- `#{signature(l)}` #{description(l.unbound)}\n"
      end
    end
    out << "\n### Also on every node\n\n"
    NAMES_ONLY.each_key { |label| out << "- #{label}: #{names_only(label).join(' ')}\n" }
    out
  end

  # Public method names of NAMES_ONLY[+label+]'s modules, aliases folded
  # in as name/alias
  def names_only(label)
    load_library
    NAMES_ONLY.fetch(label).flat_map { |m|
      mod = Object.const_get(m)
      names = mod.public_instance_methods(false).reject { |n| n.end_with?('=', '?') || n == :pretty_print }
      names.filter_map { |n|
        next if mod.instance_method(n).original_name != n

        [n, *names.select { |a| a != n && mod.instance_method(a).original_name == n }].join('/')
      }
    }.sort
  end

  def topics
    load_library
    MB::Sound::Help::TOPICS.values
  end

  # A topic's line: its commands, then its DSL names that aren't GraphNode
  # DSL methods (those have their own lines), e.g. Tone's .square
  def topic_line(t, dsl_names = dsl_lines.flat_map(&:names))
    names = (t.commands.map(&:to_s) + (t.dsl - dsl_names).map { |n| ".#{n}" }).uniq
    shown = names.first(TOPIC_NAMES_SHOWN)
    shown << '...' if names.length > TOPIC_NAMES_SHOWN
    "- `:#{t.name}` #{t.title}#{shown.empty? ? '' : ": #{shown.join(' ')}"}\n"
  end

  def console_section
    out = +"## Console help topics\n\n"
    out << "`help :topic` in the console (`bin/sound.rb`; `require 'mb/sound/dsl'` in a script): its title and commands (`.name`: methods of Tones, clips, ...).\n"
    dsl_names = dsl_lines.flat_map(&:names)
    groups = MB::Sound::Help::GROUPS
    topics.group_by(&:group).sort_by { |g, _| groups.keys.index(g) }.each do |g, ts|
      out << "\n### #{groups.fetch(g)}\n\n"
      ts.each { |t| out << topic_line(t, dsl_names) }
    end
    out
  end

  def text
    out = +<<~HEAD
      # mb-sound library catalog

      <!-- Generated by `rake docs:index` (spec/catalog.rb) from the DSL's doc comments and the help topics; edit those (and Catalog::GROUPS), not this file. -->

      What the library has, one line each: build on these ("How we build"); design/notes/README.md has each subsystem's note.

    HEAD
    out << dsl_section << "\n" << console_section
  end

  # Messages for problems the guard spec reports (empty when fine)
  def problems
    lines = dsl_lines
    grouped = GROUPS.values.flatten
    problems = []
    grouped.tally.select { |_, k| k > 1 }.each_key { |n| problems << "#{n} is in more than one Catalog::GROUPS entry" }
    lines.reject(&:group).each { |l| problems << "DSL method #{l.name} (#{l.owner.name}) is in no Catalog::GROUPS entry (spec/catalog.rb)" }
    (grouped - lines.map(&:name)).each { |n| problems << "Catalog::GROUPS names #{n}, which is no public DSL method (or is an alias)" }
    lines.each do |l|
      d = description(l.unbound)
      if d.empty?
        problems << "DSL method #{l.name} (#{l.owner.name}) has no doc comment (write one above its def)"
      elsif d.length > DESCRIPTION_MAX
        problems << "DSL method #{l.name}'s description is #{d.length} characters (at most #{DESCRIPTION_MAX}): " \
          "shorten the first sentence of its doc comment (#{l.unbound.source_location&.join(':')})"
      end
    end
    t = text
    t.each_line.with_index(1) do |line, i|
      next unless line.start_with?('- `')

      problems << "design/catalog.md line #{i} is #{line.chomp.bytesize} bytes (at most #{LINE_MAX}): #{line[0, 60]}..." if line.chomp.bytesize > LINE_MAX
    end
    problems << "design/catalog.md is #{t.bytesize} bytes (Catalog::BUDGET #{BUDGET})" if t.bytesize > BUDGET
    problems
  end

  def stale?
    !File.exist?(PATH) || File.read(PATH) != text
  end

  def write!
    File.write(PATH, text)
  end
end
