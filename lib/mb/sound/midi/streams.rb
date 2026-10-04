# The pull-based MIDI event layer (in progress; it will replace Manager,
# GraphVoice, and the MidiDsl callbacks): Events from Sources, read once for
# many readers by Streams, with stream transforms.  Loaded after Sequence,
# since ClipSource follows the sequence timeline.
require_relative 'event'
