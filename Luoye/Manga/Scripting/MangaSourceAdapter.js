function __entries(value) { return value instanceof Map ? Array.from(value.entries()) : Object.entries(value || {}); }
const __comicDetailsCache = new Map();
__source.__details = async id => {
    if (!__comicDetailsCache.has(id)) {
        const pending = Promise.resolve().then(() => __source.comic.loadInfo(id));
        __comicDetailsCache.set(id, pending);
        pending.catch(() => { if (__comicDetailsCache.get(id) === pending) __comicDetailsCache.delete(id); });
    }
    return await __comicDetailsCache.get(id);
};
__source.__refreshChapterList = async id => {
    __comicDetailsCache.delete(id);
    return await __source.__chapterList(id);
};
__source.__chapterList = async id => {
    const details = await __source.__details(id);
    const chapters=[];
    for (const [key,value] of __entries(details.chapters)) {
        if (typeof value === 'string' || typeof value === 'number') chapters.push({id:String(key),title:String(value),group:''});
        else for (const [id,title] of __entries(value)) chapters.push({id:String(id),title:String(title),group:String(key)});
    }
    if (!chapters.length) chapters.push({id:'',title:'阅读漫画',group:''});
    return {details,chapters};
};
const __sourceCursors = new Map();
const __imageConfigurations = new Map();
__source.__discover = async (page,index=0) => {
    const entry=__source.explore?.[index];
    if(!entry) throw new Error('此漫画源没有发现页');
    let result;
    if(typeof entry.load === 'function') result=await entry.load(['multiPartPage','singlePageWithMultiPart'].includes(entry.type) ? null : page);
    else if(typeof entry.loadNext === 'function') {
        const key='discover:'+index+':'+page;
        result=await entry.loadNext(page===1?null:__sourceCursors.get(key));
        __sourceCursors.set('discover:'+index+':'+(page+1),result.next);
    } else throw new Error('此漫画源没有可用的发现接口');
    const comics=[];
    const visited=new WeakSet();
    function collect(value) {
        if(value && typeof value==='object'){if(visited.has(value))return;visited.add(value);}
        if(Array.isArray(value)) for(const item of value) collect(item);
        else if(value && value.id!==undefined && value.title!==undefined) comics.push(value);
        else if(value instanceof Map) { for(const item of value.values())collect(item); }
        else if(value && typeof value==='object') { for(const item of Object.values(value))collect(item); }
    }
    collect(result);
    return {comics,next:result?.next ?? null,maxPage:result?.maxPage ?? null};
};
__source.__search = async (query,page,options=null) => {
    const search=__source.search;
    if(!search)throw new Error('此漫画源不支持搜索');
    const values=options || (search.optionList||[]).map(option=>option.default ?? String(option.options?.[0]||'').split('-')[0]);
    if(typeof search.load==='function')return await search.load(query,values,page);
    const key='search:'+query+':'+page;
    const result=await search.loadNext(query,values,page===1?null:__sourceCursors.get(key));
    __sourceCursors.set('search:'+query+':'+(page+1),result.next);
    return result;
};
__source.__imageRequests = async (comicID,chapterID) => {
    const result=await __source.comic.loadEp(comicID,chapterID || null);
    const images=Array.isArray(result)?result:result.images;
    if(!Array.isArray(images))throw new Error('漫画源返回的图片列表无效');
    const requests=[];
    for(const image of images) {
        const key=typeof image==='string'?image:image.url;
        const config=typeof __source.comic.onImageLoad==='function' ? (await __source.comic.onImageLoad(key,comicID,chapterID)) || {} : {};

        const url=config.url || key;
        const headers={...(config.headers||{})};
        const cookies=Network.getCookies(url);
        if(cookies.length && !headers.Cookie && !headers.cookie)headers.Cookie=cookies.map(c=>c.name+'='+c.value).join('; ');
        const processingKey=JSON.stringify([comicID,chapterID,key]);
        __imageConfigurations.set(processingKey,config);
        requests.push({url,headers,processingKey});
    }
    return requests;
};
__source.__setSetting = (key,value) => sendMessage({method:'save_setting',key:__source.key,setting_key:key,value});
__source.__login = async(account,password) => {
    if(typeof __source.account?.login!=='function')throw new Error('此漫画源不支持密码登录');
    const result=await __source.account.login(account,password);
    if(!result)throw new Error('漫画源未确认登录成功');
    sendMessage({method:'setLogged',value:true});
    return true;
};
__source.__logout = async() => {
    if(typeof __source.account?.logout==='function')await __source.account.logout();
    sendMessage({method:'setLogged',value:false});return true;
};

__source.__currentSettings = () => Object.fromEntries(Object.keys(__source.settings||{}).map(key=>[key,__source.loadSetting(key)]));
UI.showMessage = message => { sendMessage({method:'UI',function:'showMessage',message:String(message)}).catch(()=>{}); };
UI.showDialog = async(title,content,actions=[]) => {
    const index=await sendMessage({method:'UI',function:'showDialog',title,content,options:actions.map(a=>a.text)});
    if(index!==null && actions[index]?.callback)await actions[index].callback();
};
UI.showInputDialog = async(title,validator,image) => {
    while(true) {
        const value=await sendMessage({method:'UI',function:'showInputDialog',title,image});
        if(value===null)return null;
        const error=typeof validator==='function'?validator(value):null;
        if(!error)return value;
        UI.showMessage(error);
    }
};
UI.showSelectDialog = (title,options,initialIndex) => sendMessage({method:'UI',function:'showSelectDialog',title,options,initialIndex});
UI.launchUrl = url => sendMessage({method:'UI',function:'launchUrl',url});
UI.showLoading = () => ++__nativeSequence;
UI.cancelLoading = () => {};
__source.__webLoginCheck = (url,title) => __source.account?.loginWithWebview?.checkStatus(url,title) || false;
__source.__webLoginSuccess = async() => {
    if(__source.account?.loginWithWebview?.onLoginSuccess)await __source.account.loginWithWebview.onLoginSuccess();
    sendMessage({method:'setLogged',value:true});return true;
};
__source.__cookieLogin = async(values) => {
    const result=await __source.account.loginWithCookies.validate(values);
    if(!result)throw new Error('Cookie 登录验证失败');
    sendMessage({method:'setLogged',value:true});return true;
};

__source.__comments = async(comicId,subId,chapterId,page,replyTo) => {
    if(chapterId!==null) {
        if(!__source.comic.loadChapterComments)throw new Error('此漫画源没有章节评论');
        return await __source.comic.loadChapterComments(comicId,chapterId,page,replyTo);
    }
    if(!__source.comic.loadComments)throw new Error('此漫画源没有作品评论');
    return await __source.comic.loadComments(comicId,subId,page,replyTo);
};
__source.__sendComment = async(comicId,subId,chapterId,content,replyTo) => {
    const result=chapterId!==null ? await __source.comic.sendChapterComment(comicId,chapterId,content,replyTo) : await __source.comic.sendComment(comicId,subId,content,replyTo);
    if(!result)throw new Error('漫画源未确认评论发送成功');
    return true;
};

__source.__processImageResponse = async(key,bytes) => {
    const config=__imageConfigurations.get(key)||{};
    if(typeof config.onResponse==='function')bytes=await config.onResponse(bytes);
    if(config.modifyImage) {
        try {
            const imageKey=sendMessage({method:'image',function:'decode',data:bytes});
            const apply=new Function('image',config.modifyImage+'; return modifyImage(image);');
            const result=apply(new Image(imageKey));
            bytes=sendMessage({method:'image',function:'encode',key:result.key});
        } finally { sendMessage({method:'image',function:'dispose'}); }
    }
    return bytes;
};
__source.__thumbnailRequest = async(url,comicID) => {
    if(url.startsWith('cover.'))url=(await __source.__details(comicID)).cover;
    const config=typeof __source.comic?.onThumbnailLoad==='function'?(await __source.comic.onThumbnailLoad(url))||{}:{};
    const target=config.url || url;
    const headers={...(config.headers||{})};
    const cookies=Network.getCookies(target);
    if(cookies.length && !headers.Cookie && !headers.cookie)headers.Cookie=cookies.map(c=>c.name+'='+c.value).join('; ');
    const processingKey='thumbnail:'+comicID+':'+url;
    __imageConfigurations.set(processingKey,{onResponse:config.onResponse});
    return {url:target,headers,processingKey};
};
__source.__categories = async() => {
    const output=[];
    for(const part of __source.category?.parts||[]) {
        let values=part.categories;
        if(typeof values==='function')values=await values();
        if(!Array.isArray(values))continue;
        output.push({name:part.name,items:values.map((name,index)=>({name,param:part.categoryParams?.[index] ?? part.groupParam ?? null,type:part.itemType||'category'}))});
    }
    return output;
};
__source.__categoryComics = async(category,param,page,options=null) => {
    const config=__source.categoryComics;
    if(!config)throw new Error('此漫画源没有分类接口');
    const values=options || (config.optionList||[]).filter(o=>!o.notShowWhen?.includes(category) && (!o.showWhen||o.showWhen.includes(category))).map(o=>o.default??String(o.options?.[0]||'').split('-')[0]);
    if(config.load)return await config.load(category,param,values,page);
    const key=JSON.stringify([category,param,page]);
    const result=await config.loadNext(category,param,values,page===1?null:__sourceCursors.get(key));
    __sourceCursors.set(JSON.stringify([category,param,page+1]),result.next);
    return result;
};
__source.__tagComics = async(namespace,tag,page) => {
    const target=__source.comic.onClickTag?await __source.comic.onClickTag(namespace,tag):{page:'search',attributes:{keyword:tag}};
    if(target.page==='search')return await __source.__search(target.attributes.keyword,page,target.attributes.options||null);
    if(target.page==='category')return await __source.__categoryComics(target.attributes.category,target.attributes.param,page,target.attributes.options||null);
    throw new Error('此标签没有可浏览的分类');
};
__source.__favoriteFolders = async(comicId=null) => {
    const favorites=__source.favorites;
    if(!favorites)throw new Error('此漫画源没有源站收藏功能');
    if(!favorites.multiFolder)return {folders:[{id:'',name:'源站收藏'}],favorited:[]};
    const result=await favorites.loadFolders(comicId);
    return {folders:__entries(result.folders).map(([id,name])=>({id:String(id),name:String(name)})),favorited:result.favorited||[]};
};
__source.__favoriteList = async(folder,page) => {
    const favorites=__source.favorites;
    if(!favorites)throw new Error('此漫画源没有源站收藏功能');
    if(favorites.loadComics)return await favorites.loadComics(page,folder||null);
    const key='favorites:'+folder+':'+page;
    const result=await favorites.loadNext(page===1?null:__sourceCursors.get(key),folder||null);
    __sourceCursors.set('favorites:'+folder+':'+(page+1),result.next);
    return result;
};
__source.__changeFavorite = async(comicID,folder,adding,favoriteID=null) => {
    await __source.favorites.addOrDelFavorite(comicID,folder,adding,favoriteID);
    __comicDetailsCache.delete(comicID);
    return true;
};

// The runtime already executes outside the main thread. Await the result here so
// async compute functions and typed arrays retain their original JS values.
globalThis.compute = async (func, ...args) => {
    const callback = typeof func === 'function' ? func : (0, eval)('(' + func + ')');
    if(typeof callback !== 'function') throw new Error('compute requires a function');
    return await callback(...args);
};
