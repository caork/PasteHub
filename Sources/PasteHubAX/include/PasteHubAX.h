#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// If `prompt` is true, macOS shows the Accessibility dialog for *this* binary.
bool PasteHubAXIsTrusted(bool prompt);

#ifdef __cplusplus
}
#endif
