/* Diagnostic-only call accounting. Every wrapped runtime function executes
   unchanged. No finalizer, runtime lock function or soft link is replaced. */
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <inttypes.h>
void __real_system__finalization_primitives__attach_object_to_collection(void *, void *, void *);
void __wrap_system__finalization_primitives__attach_object_to_collection(void *, void *, void *);
void __real_system__task_lock__lock(void);
void __wrap_system__task_lock__lock(void);
void epub_collection_profile_dump(void);
typedef struct { uintptr_t key; uint64_t calls; } Stat;
typedef struct { _Alignas(128) DWORD tid; Stat stats[128]; } Row;
_Alignas(128) static Row rows[64];
static void count(uintptr_t key) {
  DWORD tid = GetCurrentThreadId();
  for (unsigned i=0; i<64U; i++) {
    Row *r=&rows[i];
    if (r->tid==tid || (r->tid==0 && InterlockedCompareExchange((volatile LONG *)&r->tid,(LONG)tid,0)==0)) {
      for(unsigned j=0;j<128U;j++) if(r->stats[j].key==key || r->stats[j].key==0) {
        r->stats[j].key=key; r->stats[j].calls++; return;
      }
      abort();
    }
  }
  abort();
}
void __wrap_system__finalization_primitives__attach_object_to_collection(void *object,void *finalize,void *collection) {
  count((uintptr_t)collection);
  __real_system__finalization_primitives__attach_object_to_collection(object,finalize,collection);
}
void __wrap_system__task_lock__lock(void) { count(1); __real_system__task_lock__lock(); }
void epub_collection_profile_dump(void) {
  wchar_t path[32768]; DWORD n=GetEnvironmentVariableW(L"EPUB_LOCK_PROFILE_PATH",path,32768);
  if(n==0 || n>=32768) return;
  HANDLE file=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
  if(file==INVALID_HANDLE_VALUE) return;
  const char header[]="thread,key,calls\n"; DWORD written;
  WriteFile(file,header,(DWORD)(sizeof(header)-1),&written,NULL);
  for(unsigned i=0;i<64U;i++) for(unsigned j=0;j<128U;j++) if(rows[i].stats[j].key) {
    char line[256]; int len=snprintf(line,sizeof(line),"%lu,0x%" PRIxPTR ",%" PRIu64 "\n",(unsigned long)rows[i].tid,rows[i].stats[j].key,rows[i].stats[j].calls);
    if(len>0 && len<(int)sizeof(line)) WriteFile(file,line,(DWORD)len,&written,NULL);
  }
  CloseHandle(file);
}