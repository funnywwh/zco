// 编译时配置
// 此文件用于控制是否使用自定义汇编实现的 ucontext
// 设置为 true 使用自定义实现（仅支持 x86_64 Linux）
// 设置为 false 使用系统 ucontext 实现
pub const use_custom_ucontext = true;
