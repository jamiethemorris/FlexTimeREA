// Private bounded whole-source analysis through the installed host-used API.
// File IO is confined to a compile-time owned experiment directory. Not realtime.
#pragma once
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <cstdio>
#include <string>
#include <cstdint>
#include <cstring>
#include <array>
#include <vector>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <dlfcn.h>
#ifndef ANALYSIS_DIRECTORY
#error Set an owned private analysis directory explicitly
#endif
namespace source_analysis {
struct Lib {void*h=nullptr;explicit Lib(const char*n){std::string p="/Applications/Logic Pro.app/Contents/Frameworks/";p+=n;p+=".framework/Versions/A/";p+=n;h=dlopen(p.c_str(),RTLD_NOW|RTLD_LOCAL);if(!h)throw std::runtime_error("analysis library unavailable");}~Lib(){if(h)dlclose(h);}template<class T>T get(const char*n){auto p=dlsym(h,n);if(!p)throw std::runtime_error("analysis symbol unavailable");return reinterpret_cast<T>(p);}};
struct List {unsigned char*begin,*end,*capacity;uint64_t metadata;~List(){::operator delete(begin);}};
static_assert(sizeof(List)==32);
// Logic 13.0/7801 ARM64 only, admitted by the supervisor's exact framework pins.
// MAFiles: native stack objects at 0x6ab0..0x6b4c have stride 0x88;
// copy constructor 0xd198 initializes through byte 0x81. Do not use old 0x68.
// Native destructor 0x5900 invalidates caches, Init-equivalent clears state,
// then deletes the long string at +0x18 iff byte +0x2f has its high bit set.
// Keep cache/shared ownership in native exports; no private-address calls or
// reconstructed atomics. See ATTRIBUTION.md for provenance and version limits.
struct Ref {
 std::array<uint64_t,4> before;
 alignas(8) unsigned char object[0x88];
 std::array<uint64_t,4> after;
 void(*invalidate)(const void*);void(*init)(void*);
 Ref(Lib&files,const char*path){
  auto none=files.get<const void*(*)()>("_ZN8CFileRef4NoneEv");
  auto copy=files.get<void(*)(void*,const void*)>("_ZN8CFileRefC1ERKS_");
  auto set=files.get<bool(*)(void*,const char*,bool)>("_ZN8CFileRef3SetEPKcb");
  invalidate=files.get<void(*)(const void*)>("_ZNK8CFileRef15InvalidateCacheEv");
  init=files.get<void(*)(void*)>("_ZN8CFileRef4InitEv");
  before.fill(0xfedcba9876543210);after=before;
  copy(object,none());
  try{check();if(!set(object,path,false))throw std::runtime_error("analysis source path");check();}
  catch(...){release();throw;}
 }
 Ref(const Ref&)=delete;Ref&operator=(const Ref&)=delete;
 void release()noexcept{
  invalidate(object);init(object);
  if(object[0x2f]&0x80){void*p;memcpy(&p,object+0x18,sizeof p);::operator delete(p);}
 }
 ~Ref(){release();check();}
 void check()const{for(auto x:before)if(x!=0xfedcba9876543210)throw std::runtime_error("analysis pre canary");for(auto x:after)if(x!=0xfedcba9876543210)throw std::runtime_error("analysis post canary");}
};
struct File {int fd=-1;~File(){if(fd>=0)::close(fd);}void write(const void*p,size_t n){auto*b=static_cast<const char*>(p);while(n){ssize_t w=::write(fd,b,n);if(w<=0)throw std::runtime_error("analysis source write");b+=w;n-=w;}}void close(){int v=fd;fd=-1;if(::close(v))throw std::runtime_error("analysis source close");}};
// Own one exclusive path, not a directory scan. Keep its inode pinned until
// after native result/CFileRef destruction; never unlink a replacement path.
struct SourceFile {
 std::string name=ANALYSIS_DIRECTORY "/source-XXXXXX.wav";
 int fd=-1;
 SourceFile(){fd=mkstemps(name.data(),4);if(fd<0)throw std::runtime_error("analysis exclusive file");}
 SourceFile(const SourceFile&)=delete;
 SourceFile&operator=(const SourceFile&)=delete;
 ~SourceFile(){
  struct stat owned{},current{};
  if(fd>=0&&fstat(fd,&owned)==0&&lstat(name.c_str(),&current)==0&&
     S_ISREG(current.st_mode)&&owned.st_dev==current.st_dev&&owned.st_ino==current.st_ino)
   ::unlink(name.c_str()); // Best effort; no race/concurrency or crash guarantee.
  if(fd>=0)::close(fd);
 }
};
inline std::vector<int64_t> derive(const float*pcm,size_t frames,int ch,int rate){
 if(!pcm||frames==0||(ch!=1&&ch!=2)||(rate!=44100&&rate!=48000)||frames>(UINT32_MAX-36ULL)/(unsigned(ch)*4))throw std::runtime_error("analysis source bounds");
 for(size_t i=0;i<frames*ch;i++)if(!std::isfinite(pcm[i]))throw std::runtime_error("nonfinite analysis source");
 SourceFile source;const auto&name=source.name;
 File f;f.fd=dup(source.fd);if(f.fd<0)throw std::runtime_error("analysis source descriptor");
 uint32_t bytes=uint32_t(frames*ch*4);unsigned char header[44]{};memcpy(header,"RIFF",4);uint32_t riff=bytes+36;memcpy(header+4,&riff,4);memcpy(header+8,"WAVEfmt ",8);uint32_t fmt=16;memcpy(header+16,&fmt,4);uint16_t format=3,nch=ch,align=ch*4,bits=32;memcpy(header+20,&format,2);memcpy(header+22,&nch,2);memcpy(header+24,&rate,4);uint32_t speed=rate*align;memcpy(header+28,&speed,4);memcpy(header+32,&align,2);memcpy(header+34,&bits,2);memcpy(header+36,"data",4);memcpy(header+40,&bytes,4);f.write(header,44);f.write(pcm,bytes);f.close();
 Lib music("MAMusicAnalysis"),files("MAFiles");Ref ref(files,name.c_str());ref.check();
 auto result=music.get<List(*)(const void*,void*,int)>("_ZN12MetroDefault22AnalyzeAudioFileOnsetsERK8CFileRefU13block_pointerFvfPbEi")(ref.object,nullptr,0);ref.check();
 uintptr_t b=(uintptr_t)result.begin,e=(uintptr_t)result.end,c=(uintptr_t)result.capacity;
 if(e<b||c<e||(e-b)%36||(e-b)/36>frames+1)throw std::runtime_error("analysis list extent");
 std::vector<int64_t> cuts{0};
 for(size_t i=0;i<(e-b)/36;i++){int64_t pos;float weight,threshold;auto p=result.begin+36*i;memcpy(&pos,p,8);memcpy(&weight,p+8,4);memcpy(&threshold,p+16,4);if(!std::isfinite(weight)||!std::isfinite(threshold))throw std::runtime_error("analysis nonfinite metadata");
  // MAAudioEngine 0x7f3040..0x7f3068: visibility/weight and interior bounds.
  if(threshold>0&&weight>=threshold&&pos>=1&&pos<int64_t(frames))cuts.push_back(pos);
 }
 std::sort(cuts.begin(),cuts.end());cuts.erase(std::unique(cuts.begin(),cuts.end()),cuts.end());cuts.push_back(frames);return cuts;
}
struct Range {int64_t source,sourceLength,dest,destLength;uint8_t first,last,padding[6];void*analysis;};
static_assert(sizeof(Range)==48);
struct Markers {
 void**vptr;std::vector<int64_t>cuts;double factor=1;uint64_t calls=0;
 static void unknown(){throw std::runtime_error("unknown marker virtual");}
 Markers(){static void*vt[]={(void*)unknown,(void*)unknown,(void*)fill,(void*)unknown};vptr=vt;}
 static int fill(Markers*p,Range*r,double pos,bool flag){
  if(!r||p->cuts.size()<2||flag||!std::isfinite(pos)||pos<0||pos>p->cuts.back()*p->factor+65536||++p->calls>100000)throw std::runtime_error("marker range bounds");
  size_t i=0;while(i+2<p->cuts.size()&&pos>=std::llround(p->cuts[i+1]*p->factor))i++;
  int64_t a=p->cuts[i],b=p->cuts[i+1];if(pos>=std::llround(b*p->factor)){a=b;b+=131072;}
  int64_t x=std::llround(a*p->factor),y=std::llround(b*p->factor);if(y<=x)throw std::runtime_error("collapsed marker interval");
  *r={a,b-a,x,y-x,1,1,{},nullptr};return 0;
 }
 void analyze(const float*pcm,size_t frames,int ch,int rate,double stretch){if(!std::isfinite(stretch)||stretch<.5||stretch>2)throw std::runtime_error("marker stretch");cuts=derive(pcm,frames,ch,rate);factor=stretch;calls=0;for(size_t i=1;i<cuts.size();i++)if(std::llround(cuts[i]*factor)<=std::llround(cuts[i-1]*factor))throw std::runtime_error("collapsed analysis interval");}
};
}
