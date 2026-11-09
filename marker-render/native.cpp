// Bounded offline native CLI using the project source-provider ABI adapter.
#include "piecewise.hpp"
#include <fstream>
#include <iostream>
struct Source {
 void**v; int rate,ch; bool prime=false; uint64_t reads=0,readLimit=0; std::vector<float>data;
 static void unknown(){throw std::runtime_error("source virtual");}
 static double sr(Source*p){return p->rate;} static unsigned nc(Source*p){return p->ch;}
 static bool read(Source*p,float**o,unsigned c,unsigned start,unsigned n,bool a,bool b,unsigned*t){
  if(!o||c!=unsigned(p->ch)||a||b||n>65536||++p->reads>p->readLimit)throw std::runtime_error("source read bounds");
  for(unsigned k=0;k<c;k++)if(!o[k])throw std::runtime_error("source null channel");
  if(t)*t=UINT32_MAX;
  for(unsigned k=0;k<c;k++)for(unsigned i=0;i<n;i++){size_t j=(size_t(start)+i)*c+k;o[k][i]=!p->prime&&j<p->data.size()?p->data[j]:0;}
  return true;
 }
 Source(const char*path,int r,int c):rate(r),ch(c){static void*vt[]={(void*)unknown,(void*)unknown,(void*)unknown,(void*)sr,(void*)nc,(void*)unknown,(void*)read};v=vt;
  std::ifstream f(path,std::ios::binary|std::ios::ate);auto bytes=f.tellg();if(bytes<=0||bytes%(ch*4)||uint64_t(bytes)>UINT32_MAX-36ULL)throw std::runtime_error("source extent");data.resize(size_t(bytes)/4);f.seekg(0);f.read((char*)data.data(),bytes);if(!f)throw std::runtime_error("source input");
 }
};
int main(int argc,char**argv){try{
 if(argc!=7)throw std::runtime_error("source.f32 output.f32 rate channels map.txt cuts.txt");
 int rate=std::stoi(argv[3]),ch=std::stoi(argv[4]);if((rate!=44100&&rate!=48000)||(ch!=1&&ch!=2))throw std::runtime_error("format");
 Source source(argv[1],rate,ch);std::vector<std::pair<int64_t,int64_t>>points;std::ifstream f(argv[5]);int64_t s,d;while(f>>s>>d){if(points.size()>=source.data.size()/ch+1)throw std::runtime_error("map capacity");points.emplace_back(s,d);}if(!f.eof()||points.size()<2)throw std::runtime_error("map file");
 Piecewise map;map.prepare(source.data.data(),source.data.size()/ch,ch,rate,points);source.readLimit=map.callLimit;
 {std::ofstream cuts(argv[6]);for(auto n:map.cuts)cuts<<n<<'\n';if(!cuts)throw std::runtime_error("cuts output");}
 source_analysis::Lib lib("MADSP");auto destroy=lib.get<void(*)(void*)>("_ZN13CElasticAudio25DestroyElasticAudioObjectEPS_");
 void*engine=lib.get<void*(*)(int,bool,int,int)>("_ZN13CElasticAudio24CreateElasticAudioObjectENS_17eElasticAudioTypeEbii")(5,true,ch,1024);if(!engine)throw std::runtime_error("factory");
 struct Guard{void*p;decltype(destroy)fn;~Guard(){fn(p);}}guard{engine,destroy};
 auto reset=lib.get<void(*)(void*)>("_ZN15CEAPhaseVocoder5resetEv");auto stretch=lib.get<void(*)(void*,double,double,int)>("_ZN15CEAPhaseVocoder28SetTransposeAndStretchfactorEdd21eElasticPreRenderMode");auto warp=lib.get<void(*)(void*,void*)>("_ZN15CEAPhaseVocoder21SetWarpMarkerProviderEP18WarpMarkerProvider");auto render=lib.get<int(*)(void*,double,unsigned,float**)>("_ZN15CEAPhaseVocoder19renderStretchedLoopEdjPPf");
 lib.get<void(*)(void*,double)>("_ZN15CEAPhaseVocoder13SetSamplerateEd")(engine,rate);lib.get<void(*)(void*,void*)>("_ZN15CEAPhaseVocoder20SetAudioDataProviderEP18CAudioDataProvider")(engine,&source);
 double factor=double(points.back().second)/(source.data.size()/ch);warp(engine,nullptr);reset(engine);stretch(engine,0,factor,6);
 std::array<float,1026>a,b;float*o[]={a.data()+1,b.data()+1};source.prime=true;if(render(engine,0,512,o))throw std::runtime_error("initialization");source.prime=false;warp(engine,&map);reset(engine);stretch(engine,0,factor,6);
 size_t total=points.back().second;std::array<float,2048>block;
 int fd=open(argv[2],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)throw std::runtime_error("exclusive output");source_analysis::File out;out.fd=fd;
 for(size_t pos=0;pos<total;){unsigned n=std::min<size_t>(1024,total-pos);a.fill(NAN);b.fill(NAN);a[0]=b[0]=a[n+1]=b[n+1]=12345;
  if(render(engine,pos,n,o))throw std::runtime_error("render");for(unsigned i=0;i<n;i++)for(int c=0;c<ch;c++){if(!std::isfinite(o[c][i]))throw std::runtime_error("nonfinite");block[i*ch+c]=o[c][i];}
  if(a[0]!=12345||b[0]!=12345||a[n+1]!=12345||b[n+1]!=12345)throw std::runtime_error("output canary");out.write(block.data(),size_t(n)*ch*4);pos+=n;
 }
 out.close();
 std::cout<<"frames="<<total<<" cuts="<<map.cuts.size()<<" calls="<<map.calls<<" source_reads="<<source.reads<<" call_limit="<<map.callLimit<<" finite/canaries=pass\n";return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
