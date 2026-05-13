// Released under the MIT License.
// Copyright, 2026, by Samuel Williams.

#include <ruby.h>

#if defined(HAVE_LINUX_INET_DIAG_H) || defined(__linux__)
void Init_IO_Metrics_Listener(VALUE IO_Metrics);
#endif

void Init_IO_Metrics(void)
{
	VALUE IO_Metrics = rb_define_module_under(rb_cIO, "Metrics");
	
#if defined(HAVE_LINUX_INET_DIAG_H) || defined(__linux__)
	Init_IO_Metrics_Listener(IO_Metrics);
#endif
}
