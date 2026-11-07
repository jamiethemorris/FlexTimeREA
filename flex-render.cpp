// Experimental host wrapper for a separately installed private framework.
// No vendor DSP implementation is included. See README.md for ABI limits.
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <fstream>
#include <cmath>
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <fcntl.h>
#include <unistd.h>

constexpr auto kMADSP="/Applications/Logic Pro.app/Contents/Frameworks/MADSP.framework/Versions/A/MADSP";
template<class T> T symbol(void* handle,const char* name) {
    dlerror(); void* p=dlsym(handle,name);
    if (const char* err=dlerror()) throw std::runtime_error(std::string(name)+": "+err);
    return reinterpret_cast<T>(p);
}
struct Library {
    void* handle;
    Library():handle(dlopen(std::getenv("FLEX_MADSP")?std::getenv("FLEX_MADSP"):kMADSP,RTLD_NOW|RTLD_LOCAL)) {
        if (!handle) throw std::runtime_error(dlerror());
    }
    ~Library(){ if(handle) dlclose(handle); }
};
using Create=void*(*)(int,bool,int,int);
using Destroy=void(*)(void*);
struct Engine {
    Destroy destroy;
    void* object;
    Engine(Library& lib,int channels,int mode=5):
      destroy(symbol<Destroy>(lib.handle,"_ZN13CElasticAudio25DestroyElasticAudioObjectEPS_")),
      object(symbol<Create>(lib.handle,"_ZN13CElasticAudio24CreateElasticAudioObjectENS_17eElasticAudioTypeEbii")(mode,true,channels,1024)) {
        if (!object) throw std::runtime_error("MADSP factory returned null");
    }
    ~Engine(){if(object) destroy(object);}
    void close(){if(object){destroy(object);object=nullptr;}}
};
// Only the seven observed CAudioDataProvider slots are supplied. Unknown calls
// terminate the owned child instead of guessing a return type or layout.
struct Provider {
    void** vptr;
    double rate;
    unsigned channels;
    bool feederReads;
    std::vector<float> input;
    uint64_t reads=0, padded=0;
    static void unexpected() { std::cerr<<"unsupported provider slot\n"; std::_Exit(3); }
    static double samplerate(Provider* p) {return p->rate;}
    static unsigned channelcount(Provider* p) {return p->channels;}
    static uint64_t length(Provider* p) {return p->input.size()/p->channels;}
    static bool read(Provider* p,float** output,unsigned nch,unsigned start,
                     unsigned count,bool flag1,bool flag2,unsigned* transient) {
        if ((flag1 && !p->feederReads) || flag2 || nch>p->channels || count>65536) {
            std::cerr<<"unsupported provider read request: channels="<<nch<<" start="<<start<<" frames="<<count<<" flag1="<<flag1<<" flag2="<<flag2<<"\n";std::_Exit(3);
        }
        ++p->reads;
        if (transient) *transient=UINT32_MAX;
        if (output) for(unsigned c=0;c<nch;++c) for(unsigned i=0;i<count;++i) {
            uint64_t frame=uint64_t(start)+i;
            bool valid=frame<length(p);
            output[c][i]=valid?p->input[frame*p->channels+c]:0.0f;
            if (!valid) ++p->padded;
        }
        return true;
    }
    Provider(double r,unsigned c,const std::string& path,bool feeder=false):rate(r),channels(c),feederReads(feeder) {
        static void* table[]={reinterpret_cast<void*>(&unexpected),reinterpret_cast<void*>(&unexpected),
            reinterpret_cast<void*>(&unexpected),reinterpret_cast<void*>(&samplerate),
            reinterpret_cast<void*>(&channelcount),reinterpret_cast<void*>(&unexpected),reinterpret_cast<void*>(&read)};
        vptr=table;
        std::ifstream f(path,std::ios::binary|std::ios::ate);
        if (!f) throw std::runtime_error("cannot open input");
        auto size=f.tellg();
        if (size<=0 || size>48000*30*2*4 || size%(channels*4)!=0) throw std::runtime_error("invalid/oversized float input");
        input.resize(size/4);f.seekg(0);
        if (!f.read(reinterpret_cast<char*>(input.data()),size)) throw std::runtime_error("short input read");
        for(float x:input) if (!std::isfinite(x)) throw std::runtime_error("nonfinite input");
    }
};
struct MarkerRange {
    int64_t sourceStart,sourceLength,outputStart,outputLength;
    uint8_t startFlag,endFlag;
    uint8_t padding[6];
    void* context;
};
static_assert(sizeof(MarkerRange)==48);
struct ConstantMap {
    void** vptr;
    std::vector<MarkerRange> ranges;
    static bool fill(ConstantMap* p,MarkerRange* out,double pos,bool reversed) {
        if(!std::isfinite(pos) || reversed) Provider::unexpected();
        auto it=std::upper_bound(p->ranges.begin(),p->ranges.end(),pos,
            [](double position,const MarkerRange& r){return position<r.outputStart;});
        if(it!=p->ranges.begin()) --it;
        *out=*it;return false; // Native marker implementations return 0.
    }
    static int64_t wrapped(ConstantMap*,int64_t position) {return position;}
    ConstantMap(uint64_t source,double stretch,const std::vector<uint64_t>& cuts) {
        static void* table[]={reinterpret_cast<void*>(&Provider::unexpected),
            reinterpret_cast<void*>(&Provider::unexpected),reinterpret_cast<void*>(&fill),
            reinterpret_cast<void*>(&wrapped),reinterpret_cast<void*>(&Provider::unexpected)};
        vptr=table;
        std::vector<uint64_t> bounds{0};bounds.insert(bounds.end(),cuts.begin(),cuts.end());bounds.push_back(source);
        for(size_t i=1;i<bounds.size();++i) {
            int64_t first=std::llround(bounds[i-1]*stretch),last=std::llround(bounds[i]*stretch);
            if(first>=last) throw std::runtime_error("transient map collapses an output interval");
            ranges.push_back({int64_t(bounds[i-1]),int64_t(bounds[i]-bounds[i-1]),first,last-first,1,1,{},nullptr});
        }
    }
};
struct Mode {
    const char* name;
    int factory;
    const char* prefix;
    const char* ratePrefix;
    bool feeder;
};
const Mode& selectMode(const std::string& name) {
    if(name=="monophonic") throw std::runtime_error("monophonic unsupported: requires native pitch-analysis provider; data ABI not recovered");
    static const Mode modes[]={
        {"polyphonic",5,"_ZN15CEAPhaseVocoder","_ZN15CEAPhaseVocoder",false},
        {"speed",2,"_ZN12CEAResampler","_ZN12CEAResampler",false},
        {"tempophone",4,"_ZN10CEAGrainer","_ZN10CEAGrainer",false},
        {"rhythmic",1,"_ZN14CStretchFeeder","_ZN10CSFStretch",true},
        {"slicing",3,"_ZN14CStretchFeeder","_ZN8CSFSlice",true}};
    for(const auto& mode:modes) if(name==mode.name) return mode;
    throw std::runtime_error("unsupported mode");
}
double numeric(const char* text) {
    try {
        std::string s(text);size_t consumed=0;double v=std::stod(s,&consumed);
        if(consumed!=s.size() || !std::isfinite(v)) throw std::runtime_error("invalid");
        return v;
    } catch(const std::exception&) {throw std::runtime_error("invalid numeric argument");}
}
unsigned integer(const char* text) {
    std::string s(text);
    if(s.empty() || !std::all_of(s.begin(),s.end(),[](char c){return c>='0'&&c<='9';})) throw std::runtime_error("invalid numeric integer");
    double v=numeric(text);
    if(v>65536) throw std::runtime_error("numeric integer exceeds limit");
    return static_cast<unsigned>(v);
}
int main(int argc,char** argv) {
    try {
        if (argc==2 && std::string(argv[1])=="smoke") {
            Library library;
            auto instances=symbol<unsigned*>(library.handle,"_ZN15CEAPhaseVocoder13m_siInstancesE");
            unsigned before=*instances;
            for(unsigned i=0;i<10;++i) {Engine engine(library,2);engine.close();}
            if(*instances!=before) throw std::runtime_error("MADSP instance count did not return to baseline");
            std::cout<<"{\"created\":true,\"destroyed\":true,\"cycles\":10,\"instances_before\":"<<before<<",\"instances_after\":"<<*instances<<"}\n";return 0;
        }
        if ((argc<7 || argc>10) || std::string(argv[1])!="render") throw std::runtime_error("usage: flex-render render input.f32 output.f32 rate channels stretch [block [mode [transient_csv]]]");
        std::string mode=argc>=9?argv[8]:"polyphonic";
        const auto& spec=selectMode(mode);
        double rate=numeric(argv[4]), stretch=numeric(argv[6]);
        unsigned channels=integer(argv[5]);
        unsigned block=argc>=8?integer(argv[7]):1024;
        if (!std::isfinite(rate) || (rate!=44100 && rate!=48000) || !std::isfinite(stretch) || stretch<0.5 || stretch>2 || channels<1 || channels>2 || block<1 || block>1024)
            throw std::runtime_error("supported: rate 44100/48000, channels 1/2, stretch 0.5..2, block 1..1024");
        Provider provider(rate,channels,argv[2],spec.feeder);
        if(Provider::length(&provider)>rate*30) throw std::runtime_error("input exceeds 30-second bound");
        auto total=static_cast<uint64_t>(std::llround(Provider::length(&provider)*stretch));
        std::vector<uint64_t> cuts;
        if(argc==10) {
            std::string csv(argv[9]);size_t start=0;
            if(csv.empty() || csv.size()>32768) throw std::runtime_error("invalid transient list");
            do {
                size_t end=csv.find(',',start);std::string token=csv.substr(start,end==std::string::npos?end:end-start);
                if(token.empty() || !std::all_of(token.begin(),token.end(),[](char c){return c>='0'&&c<='9';})) throw std::runtime_error("invalid transient integer");
                double value=numeric(token.c_str());
                if(value<=0 || value>=Provider::length(&provider) || (!cuts.empty() && value<=cuts.back()) || cuts.size()>=4096) throw std::runtime_error("invalid transient bounds/order");
                cuts.push_back(static_cast<uint64_t>(value));
                if(end==std::string::npos) break;
                start=end+1;
            } while(true);
        }
        if(spec.feeder!=!cuts.empty()) throw std::runtime_error("rhythmic/slicing requires explicit transients; other modes do not accept them");
        ConstantMap markers(Provider::length(&provider),stretch,cuts);
        Library library; Engine engine(library,channels,spec.factory);
        std::string prefix=spec.prefix;
        auto setrate=symbol<void(*)(void*,double)>(library.handle,(std::string(spec.ratePrefix)+"13SetSamplerateEd").c_str());
        auto setprovider=symbol<void(*)(void*,void*)>(library.handle,(prefix+"20SetAudioDataProviderEP18CAudioDataProvider").c_str());
        auto reset=spec.feeder?reinterpret_cast<void(*)(void*)>((*static_cast<void***>(engine.object))[0x68/8]):
            symbol<void(*)(void*)>(library.handle,(prefix+"5resetEv").c_str());
        auto render=symbol<int(*)(void*,double,unsigned,float**)>(library.handle,(prefix+"19renderStretchedLoopEdjPPf").c_str());
        auto setwarp=symbol<void(*)(void*,void*)>(library.handle,(prefix+"21SetWarpMarkerProviderEP18WarpMarkerProvider").c_str());
        setrate(engine.object,rate);setprovider(engine.object,&provider);
        setwarp(engine.object,mode!="polyphonic"?&markers:nullptr);reset(engine.object);
        if(mode!="speed") {
            auto setstretch=symbol<void(*)(void*,double,double,int)>(library.handle,(prefix+"28SetTransposeAndStretchfactorEdd21eElasticPreRenderMode").c_str());
            setstretch(engine.object,0.0,stretch,6);
        }
        std::vector<std::vector<float>> planar(channels,std::vector<float>(block));
        std::vector<float*> ptrs(channels);
        for(unsigned c=0;c<channels;++c) ptrs[c]=planar[c].data();
        std::vector<float> result;result.reserve(total*channels);
        double peak=0;
        for(uint64_t pos=0;pos<total;pos+=block) {
            unsigned count=std::min<uint64_t>(block,total-pos);
            for(auto& x:planar) std::fill(x.begin(),x.end(),std::numeric_limits<float>::quiet_NaN());
            if(render(engine.object,double(pos),count,ptrs.data())!=0) throw std::runtime_error("MADSP render failed");
            for(unsigned i=0;i<count;++i) for(unsigned c=0;c<channels;++c) {
                float x=planar[c][i]; if(!std::isfinite(x)) throw std::runtime_error("nonfinite/unwritten output");
                peak=std::max(peak,std::abs(double(x)));result.push_back(x);
            }
        }
        engine.close();
        int fd=::open(argv[3],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        if(fd<0) throw std::runtime_error("cannot exclusively create output (existing output is never overwritten)");
        const char* bytes=reinterpret_cast<const char*>(result.data());size_t remaining=result.size()*sizeof(float);
        while(remaining) {
            ssize_t n=::write(fd,bytes,remaining);
            if(n<=0) {::close(fd);throw std::runtime_error("output write failed; partial file retained");}
            bytes+=n;remaining-=n;
        }
        if(::close(fd)!=0) throw std::runtime_error("output close failed");
        std::cout<<"{\"destroyed\":true,\"output_frames\":"<<total<<",\"provider_reads\":"<<provider.reads<<",\"padded_samples\":"<<provider.padded<<",\"peak\":"<<peak<<"}\n";
        return 0;
    } catch(const std::exception& e) {std::cerr<<"flex-render: "<<e.what()<<'\n';return 2;}
}
