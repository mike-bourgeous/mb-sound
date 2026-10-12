/*
 * FastRecipe: the binding of a running block's frame, for graph recipes
 * (MB::Sound::GraphNode::Recipe.trace_locals).
 *
 * Recipes name objects after the local variables of the build blocks that
 * made them (synth lanes, feedback loops, ...).  They used to read the
 * locals with a TracePoint(:b_return) targeted at the block, but enabling
 * any TracePoint makes YJIT throw away all of its compiled code
 * (invalidate_everything), so every graph built while something played
 * (a scene change in a live set) made the render thread recompile
 * everything it ran: 50-120 ms buffers right after each build (scene-build
 * branch, 2026-10-12).
 *
 * Instead the recorder asks for the Binding of the block's frame while the
 * block runs (at its first recorded call), through the VM's public debug
 * inspector API, and reads the locals from that Binding once the block has
 * returned: a Binding shares its frame's environment, so it sees the final
 * values, as the TracePoint did at b_return.
 */
#include <ruby.h>
#include <ruby/debug.h>

struct mb_fr_find {
	VALUE iseq;
	VALUE result;
};

static VALUE mb_fr_inspect(const rb_debug_inspector_t *dc, void *data)
{
	struct mb_fr_find *f = data;
	VALUE locations = rb_debug_inspector_backtrace_locations(dc);
	long count = RARRAY_LEN(locations);

	for (long i = 0; i < count; i++) {
		VALUE iseq = rb_debug_inspector_frame_iseq_get(dc, i);
		if (iseq == f->iseq) {
			f->result = rb_debug_inspector_frame_binding_get(dc, i);
			break;
		}
	}

	return Qnil;
}

/*
 * call-seq:
 *   MB::Sound::FastRecipe.frame_binding(iseq) -> Binding or nil
 *
 * The Binding of the innermost frame on the current thread's stack running
 * +iseq+ (a RubyVM::InstructionSequence, e.g. of a block), or nil if no
 * frame runs it.
 */
static VALUE ruby_frame_binding(VALUE self, VALUE iseq)
{
	struct mb_fr_find f = { .iseq = iseq, .result = Qnil };
	rb_debug_inspector_open(mb_fr_inspect, &f);
	return f.result;
}

void Init_fast_recipe(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_recipe = rb_define_module_under(sound, "FastRecipe");

	rb_define_module_function(fast_recipe, "frame_binding", ruby_frame_binding, 1);
}
