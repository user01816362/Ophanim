// OPInterpose.h — single canonical DYLD_INTERPOSE macro.
// Replaces the 6 identical copies previously scattered across GalgalLoader.h
// and OPHooksCrypto/Socket/TLS/Pinning/Process.m. New interpose sites must
// use this header; do not redefine the macro locally.
#ifndef OPHANIM_INTERPOSE_H
#define OPHANIM_INTERPOSE_H

#define OPHANIM_INTERPOSE(_replacement, _replacee) \
  __attribute__((used)) static struct { \
    const void *replacement; \
    const void *replacee; \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
    (const void *)(unsigned long)&_replacement, \
    (const void *)(unsigned long)&_replacee \
  };

#endif
