// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 间接参数的权威字节（nvn_vk_first_draw_indirect_args）：编进真实帧队列源码，只替身 Vulkan 与外部模块。
// 证明四件事：不碰影子 = guest 权威且不同步；只读影子不改变权威；本帧可写影子 = 先等本帧在途工作完成
// 再从影子读；在途延迟帧的可写影子 = 先退休（等 fence + 回写 guest）再由 guest 读；收口失败准确报错。
#ifndef FIRST_DRAW_SOURCE
#define FIRST_DRAW_SOURCE "../native/nvn/nvn_vk_first_draw.c"
#endif
#include FIRST_DRAW_SOURCE
#include <assert.h>
#define H(T,n) ((T)(uintptr_t)(n))
static int waited[64];
VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice d,uint32_t n,const VkFence*f,VkBool32 all,uint64_t t){
  (void)d;(void)all;(void)t;assert(n==1);int x=(int)(uintptr_t)*f;assert(x<64);waited[x]++;return x==11?VK_TIMEOUT:VK_SUCCESS;}
VKAPI_ATTR VkResult VKAPI_CALL vkGetFenceStatus(VkDevice d,VkFence f){(void)d;(void)f;return VK_SUCCESS;}
VKAPI_ATTR VkResult VKAPI_CALL vkResetFences(VkDevice d,uint32_t n,const VkFence*f){(void)d;(void)n;(void)f;return VK_SUCCESS;}
#define NOOP_DESTROY(name,T) VKAPI_ATTR void VKAPI_CALL name(VkDevice d,T h,const VkAllocationCallbacks*a){(void)d;(void)h;(void)a;}
NOOP_DESTROY(vkDestroyFence,VkFence) NOOP_DESTROY(vkDestroyPipeline,VkPipeline) NOOP_DESTROY(vkDestroyBuffer,VkBuffer)
NOOP_DESTROY(vkFreeMemory,VkDeviceMemory) NOOP_DESTROY(vkDestroySampler,VkSampler) NOOP_DESTROY(vkDestroyDescriptorPool,VkDescriptorPool)
NOOP_DESTROY(vkDestroyFramebuffer,VkFramebuffer) NOOP_DESTROY(vkDestroyRenderPass,VkRenderPass) NOOP_DESTROY(vkDestroyImageView,VkImageView)
NOOP_DESTROY(vkDestroyImage,VkImage)
VKAPI_ATTR void VKAPI_CALL vkUnmapMemory(VkDevice d,VkDeviceMemory m){(void)d;(void)m;}
VKAPI_ATTR void VKAPI_CALL vkFreeCommandBuffers(VkDevice d,VkCommandPool p,uint32_t n,const VkCommandBuffer*c){(void)d;(void)p;(void)n;(void)c;}
VKAPI_ATTR VkResult VKAPI_CALL vkResetDescriptorPool(VkDevice d,VkDescriptorPool p,VkDescriptorPoolResetFlags f){(void)d;(void)p;(void)f;return VK_SUCCESS;}
VKAPI_ATTR VkResult VKAPI_CALL vkGetQueryPoolResults(VkDevice d,VkQueryPool p,uint32_t f,uint32_t n,size_t z,void*o,VkDeviceSize s,VkQueryResultFlags fl){(void)d;(void)p;(void)f;(void)n;(void)z;(void)o;(void)s;(void)fl;return VK_SUCCESS;}
// 下列入口在这些场景里不该被走到：走到就是被测路径录了新命令或建了新资源。
#define MUST_NOT(ret,name,...) VKAPI_ATTR ret VKAPI_CALL name(__VA_ARGS__){assert(!#name);abort();}
MUST_NOT(VkResult,vkAllocateMemory,VkDevice d,const VkMemoryAllocateInfo*i,const VkAllocationCallbacks*a,VkDeviceMemory*m)
MUST_NOT(VkResult,vkBindBufferMemory,VkDevice d,VkBuffer b,VkDeviceMemory m,VkDeviceSize o)
MUST_NOT(void,vkCmdCopyImageToBuffer,VkCommandBuffer c,VkImage i,VkImageLayout l,VkBuffer b,uint32_t n,const VkBufferImageCopy*r)
MUST_NOT(void,vkCmdEndRenderPass,VkCommandBuffer c)
MUST_NOT(void,vkCmdPipelineBarrier,VkCommandBuffer c,VkPipelineStageFlags s,VkPipelineStageFlags t,VkDependencyFlags f,uint32_t a,const VkMemoryBarrier*b,uint32_t e,const VkBufferMemoryBarrier*g,uint32_t h,const VkImageMemoryBarrier*i)
MUST_NOT(void,vkCmdWriteTimestamp,VkCommandBuffer c,VkPipelineStageFlagBits s,VkQueryPool p,uint32_t q)
MUST_NOT(VkResult,vkCreateBuffer,VkDevice d,const VkBufferCreateInfo*i,const VkAllocationCallbacks*a,VkBuffer*b)
MUST_NOT(VkResult,vkCreateFence,VkDevice d,const VkFenceCreateInfo*i,const VkAllocationCallbacks*a,VkFence*f)
MUST_NOT(VkResult,vkEndCommandBuffer,VkCommandBuffer c)
MUST_NOT(void,vkGetBufferMemoryRequirements,VkDevice d,VkBuffer b,VkMemoryRequirements*r)
MUST_NOT(VkResult,vkMapMemory,VkDevice d,VkDeviceMemory m,VkDeviceSize o,VkDeviceSize s,VkMemoryMapFlags f,void**p)
MUST_NOT(VkResult,vkQueueSubmit,VkQueue q,uint32_t n,const VkSubmitInfo*s,VkFence f)
int __android_log_print(int p,const char*t,const char*f,...){(void)p;(void)t;(void)f;return 0;}
int __system_property_get(const char*n,char*v){(void)n;*v=0;return 0;}
int nvn_vk_query_resolve(struct s2a_vk_device*d,char*w,size_t z){(void)d;(void)w;(void)z;return 0;}
int nvn_vk_query_batch_completed(uint64_t s,char*w,size_t z){(void)s;(void)w;(void)z;return 0;}
void nvn_vk_query_batch_submitted(uint64_t s){(void)s;}
void nvn_vk_query_pass_end(void){}
int nvn_vk_format_has_stencil(VkFormat f){(void)f;return 0;}
void s2a_poolahb_complete_seq(uint64_t seq){(void)seq;}
uint64_t s2a_vk_adapter_registry_generation(void){return 0;}
void nvn_vk_texcache_unpin(struct nvn_vk_tex*t){(void)t;}
void nvn_vk_texcache_unpin_view(struct nvn_vk_tex*t,VkImageView v){(void)t;(void)v;}
uint32_t s2a_vk_memory_type(const struct s2a_vk_device*d,uint32_t bits,VkMemoryPropertyFlags f,VkMemoryPropertyFlags*c){(void)d;(void)bits;(void)f;(void)c;return 0;}

static uint64_t A(const void *p){return (uint64_t)(uintptr_t)p;}
int main(void){
  struct s2a_vk_device d={0};d.device=H(VkDevice,1);
  char why[200];uint32_t out[5];
  static uint32_t guest[16]={1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
  static uint32_t shadow[16]={91,92,93,94,95,96,97,98,99,100,101,102,103,104,105,106};
  // 1) 没有影子：guest 权威，不同步。
  assert(nvn_vk_first_draw_indirect_args(A(guest),16,out,why,sizeof why)==0);
  assert(nvn_vk_first_draw_indirect_args(0,16,out,why,sizeof why)==-1);
  // 2) 本帧只读影子（guest 的拷贝）：不改变权威。
  g_fq.dev=&d;
  g_fq.ssbo_wb[0]=(struct fd_ssbo_wb){.buf=H(VkBuffer,5),.map=shadow,.guest=A(guest),.size=64,.writable=0};
  g_fq.n_ssbo_wb=1;
  assert(nvn_vk_first_draw_indirect_args(A(guest+4),20,out,why,sizeof why)==0);
  // 3) 本帧可写影子，本帧还有在途批次（fence 40）：必须先等它完成，再读影子里 GPU 写的字节。
  assert(fd_ssbo_wb_mark(64,0,&g_fq.ssbo_wb[0])==0);
  g_fq.nbatch_fence=1;g_fq.batch_fence[0]=H(VkFence,40);g_fq.state=FD_FQ_SUBMITTED;
  memset(out,0,sizeof out);
  assert(nvn_vk_first_draw_indirect_args(A(guest+4),20,out,why,sizeof why)==1);
  assert(waited[40]==1);
  assert(out[0]==95&&out[4]==99);
  assert(g_fq.n_ssbo_wb==1);   // 同步 flush 不回写、不丢影子：本帧后续读写仍走同一份影子
  // 同帧再读：已无在途工作，不再等。
  assert(nvn_vk_first_draw_indirect_args(A(guest),4,out,why,sizeof why)==1&&out[0]==91&&waited[40]==1);
  // 4) 一半在影子里：表达不了，准确失败。
  assert(nvn_vk_first_draw_indirect_args(A(guest+14),12,out,why,sizeof why)==-1);
  assert(strstr(why,"straddle"));
  g_fq.n_ssbo_wb=0;
  // 5) 在途延迟帧的可写影子（fence 50）：先退休（等 fence、回写 guest），再由调用方读 guest。
  static uint32_t guest2[4]={1,1,1,1},slot_map[4]={7,8,9,10};
  g_slot[0].used=1;g_slot[0].q.dev=&d;g_slot[0].q.fence=H(VkFence,50);
  g_slot[0].q.ssbo_wb[0]=(struct fd_ssbo_wb){.buf=H(VkBuffer,6),.map=slot_map,.guest=A(guest2),.size=16,.writable=1,.nwb=1,.wb={{0,16}}};
  g_slot[0].q.n_ssbo_wb=1;g_slot_cur=0;
  assert(nvn_vk_first_draw_indirect_args(A(guest2),12,out,why,sizeof why)==0);
  assert(waited[50]==1&&!g_slot[0].used);
  assert(guest2[0]==7&&guest2[2]==9);
  // 6) 在途帧拿不到完成证明（fence 11 超时）：准确失败，不读旧字节。
  static uint32_t guest3[4];
  g_slot[1].used=1;g_slot[1].q.dev=&d;g_slot[1].q.fence=H(VkFence,11);
  g_slot[1].q.ssbo_wb[0]=(struct fd_ssbo_wb){.buf=H(VkBuffer,7),.map=slot_map,.guest=A(guest3),.size=16,.writable=1,.nwb=1,.wb={{0,16}}};
  g_slot[1].q.n_ssbo_wb=1;g_slot_cur=1;
  assert(nvn_vk_first_draw_indirect_args(A(guest3),12,out,why,sizeof why)==-1);
  assert(strstr(why,"in flight"));
  puts("indirect args authority: guest / read-only shadow / frame shadow after sync / in-flight retire / failures passed");
  return 0;
}
