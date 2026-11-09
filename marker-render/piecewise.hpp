// Piecewise extension of the source_analysis::Markers provider.
// Range ABI and continuous native rendering are version-specific interoperability code.
#pragma once
#include "source_analysis.hpp"
#include <utility>
struct Piecewise {
 void**vptr;
 std::vector<int64_t>cuts,dest;
 std::vector<std::pair<int64_t,int64_t>>points;
 uint64_t calls=0,callLimit=0;
 static void unknown(){throw std::runtime_error("unknown piecewise virtual");}
 Piecewise(){static void*vt[]={(void*)unknown,(void*)unknown,(void*)fill,(void*)unknown};vptr=vt;}
 int64_t mapped(int64_t s)const{
  auto it=std::upper_bound(points.begin(),points.end(),s,[](int64_t n,const auto&p){return n<p.first;});
  size_t i=it==points.begin()?0:std::min(size_t(it-points.begin()-1),points.size()-2);
  auto a=points[i],b=points[i+1];
  return a.second+std::llround(double(s-a.first)*double(b.second-a.second)/double(b.first-a.first));
 }
 void prepare(const float*pcm,size_t frames,int ch,int rate,const std::vector<std::pair<int64_t,int64_t>>&input){
  if((ch!=1&&ch!=2)||(rate!=44100&&rate!=48000)||!frames||frames>(UINT32_MAX-36ULL)/(unsigned(ch)*4)||input.size()<2||input.size()>frames+1||input.front()!=std::make_pair(int64_t(0),int64_t(0))||input.back().first!=int64_t(frames)||input.back().second<=0||uint64_t(input.back().second)>(UINT32_MAX-36ULL)/(unsigned(ch)*4))throw std::runtime_error("map endpoints/bounds");
  // Validate signed coordinates before subtraction to avoid overflow on bad maps.
  for(size_t i=1;i<input.size();i++){
   auto a=input[i-1],b=input[i];
   if(b.first<=a.first||b.first>int64_t(frames)||b.second<=a.second||b.second>input.back().second)throw std::runtime_error("map order/local duration ratio");
   int64_t ds=b.first-a.first,dd=b.second-a.second;
   if(ds>4*dd||dd>4*ds)throw std::runtime_error("map order/local duration ratio");
  }
  // Linear stack simplification; exact wide products avoid overflow.
  points.clear();points.reserve(input.size());
  for(auto c:input){
   while(points.size()>=2){auto a=points[points.size()-2],b=points.back();
    if(__int128(b.second-a.second)*(c.first-b.first)!=__int128(c.second-b.second)*(b.first-a.first))break;
    points.pop_back();
   }
   points.push_back(c);
  }
  cuts=source_analysis::derive(pcm,frames,ch,rate);
  for(const auto&p:points)cuts.push_back(p.first);
  std::sort(cuts.begin(),cuts.end());cuts.erase(std::unique(cuts.begin(),cuts.end()),cuts.end());
  dest.clear();dest.reserve(cuts.size());for(auto s:cuts){auto d=mapped(s);if(!dest.empty()&&d<=dest.back())throw std::runtime_error("collapsed mapped analysis interval");dest.push_back(d);}calls=0;
  callLimit=4096+64*((frames+uint64_t(points.back().second)+1023)/1024)+16*cuts.size();
 }
 static int fill(Piecewise*p,source_analysis::Range*r,double pos,bool reverse){
  if(!r||p->cuts.size()<2||reverse||!std::isfinite(pos)||pos<0||pos>p->dest.back()+65536||++p->calls>p->callLimit)throw std::runtime_error("piecewise range request");
  auto it=std::upper_bound(p->dest.begin(),p->dest.end(),pos);
  size_t i=it==p->dest.begin()?0:std::min(size_t(it-p->dest.begin()-1),p->dest.size()-2);
  int64_t a=p->cuts[i],b=p->cuts[i+1],x=p->dest[i],y=p->dest[i+1];
  if(pos>=y){a=b;b+=131072;x=y;y=p->mapped(b);}
  if(y<=x)throw std::runtime_error("collapsed piecewise interval");
  *r={a,b-a,x,y-x,1,1,{},nullptr};return 0;
 }
};
