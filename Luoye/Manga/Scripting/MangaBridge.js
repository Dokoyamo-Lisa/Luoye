const __nativePending = new Map();
let __nativeSequence = 0;
function __pack(v) {
    if (v instanceof Map) return Object.fromEntries(Array.from(v.entries()).map(([k,x]) => [k,__pack(x)]));
    if (v instanceof Set) return Array.from(v).map(__pack);
    if (v instanceof ArrayBuffer) return {__bytes: Array.from(new Uint8Array(v))};
    if (ArrayBuffer.isView(v)) return {__bytes: Array.from(new Uint8Array(v.buffer, v.byteOffset, v.byteLength))};
    if (Array.isArray(v)) return v.map(__pack);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k,x]) => [k,__pack(x)]));
    return v;
}
function __unpack(v) {
    if (v && v.__bytes) return new Uint8Array(v.__bytes).buffer;
    if (Array.isArray(v)) return v.map(__unpack);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k,x]) => [k,__unpack(x)]));
    return v;
}
function __nativeReply(id, serialized) {
    const pending = __nativePending.get(id);
    if (!pending) return;
    __nativePending.delete(id);
    const response = JSON.parse(serialized);
    if (response.error) pending.reject(new Error(response.error));
    else pending.resolve(__unpack(response.value));
}
function sendMessage(message) {
    const serialized = JSON.stringify(__pack(message));
    if (message.method === 'http' || message.method === 'delay' || message.method === 'UI') {
        return new Promise((resolve,reject) => {
            const id = String(++__nativeSequence);
            __nativePending.set(id,{resolve,reject});
            __nativeAsync(serialized,id);
        });
    }
    const response = JSON.parse(__nativeSync(serialized));
    if (response.error) throw new Error(response.error);
    return __unpack(response.value);
}
function __invokeNativeSource(id,path,argsJSON) {
    const args=__unpack(JSON.parse(argsJSON));
    if(path!=='__metadata' && !globalThis.__sourceReady)globalThis.__sourceReady=Promise.resolve().then(()=>__source.init());
    Promise.resolve(path==='__metadata' ? null : globalThis.__sourceReady).then(() => {
        const keys = path.split('.');
        let owner = globalThis.__source;
        for (let i=0;i<keys.length-1;i++) owner=owner[keys[i]];
        const value=owner[keys[keys.length-1]];
        return typeof value === 'function' ? value.apply(owner,args) : value;
    }).then(value => __nativeFinish(id,JSON.stringify({value:__pack(value === undefined ? null : value)})),
            error => __nativeFinish(id,JSON.stringify({error:String(error && error.message || error)})));
}
