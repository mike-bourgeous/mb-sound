require 'json'

# Outputs of the old Sequence::ClipNode renderers (Gate, Trigger, Number,
# Velocity; removed when clips moved onto Notes), recorded at fbc075d for
# the clip cases in notes_spec and clip_source_spec, so those specs can
# still check that Notes and ClipSource put every edge on the same sample
# as ClipNode did.  Stored as run-length encoded sample values in
# spec/test_data/clip_node_reference.json.
module ClipNodeReference
  DATA = JSON.parse(File.read(File.join(__dir__, '..', 'test_data', 'clip_node_reference.json')))

  # Returns a Hash of signal name (Symbol) to an Array of samples for the
  # recorded case +name+, or the Array itself for single-signal cases.
  def self.[](name)
    data = DATA.fetch(name.to_s)
    return expand(data) if data.key?('runs')
    data.to_h { |k, v| [k.to_sym, expand(v)] }
  end

  def self.expand(rle)
    runs = rle['runs']
    out = Array.new(rle['length'])
    runs.each_with_index do |(start, value), idx|
      stop = idx + 1 < runs.length ? runs[idx + 1][0] : rle['length']
      out.fill(value, start...stop)
    end
    out
  end
end
