var Y$="1.3.25";function G$(J,Q,$){return Math.max(J,Math.min(Q,$))}function PW(J,Q,$){return(1-$)*J+$*Q}function TW(J,Q,$,Z){return PW(J,Q,1-Math.exp(-$*Z))}function SW(J,Q){return(J%Q+Q)%Q}var jW=class{isRunning=!1;value=0;from=0;to=0;currentTime=0;lerp;duration;easing;onUpdate;advance(J){if(!this.isRunning)return;let Q=!1;if(this.duration&&this.easing){this.currentTime+=J;let $=G$(0,this.currentTime/this.duration,1);Q=$>=1;let Z=Q?1:this.easing($);this.value=this.from+(this.to-this.from)*Z}else if(this.lerp){if(this.value=TW(this.value,this.to,this.lerp*60,J),Math.round(this.value)===Math.round(this.to))this.value=this.to,Q=!0}else this.value=this.to,Q=!0;if(Q)this.stop();this.onUpdate?.(this.value,Q)}stop(){this.isRunning=!1}fromTo(J,Q,{lerp:$,duration:Z,easing:W,onStart:K,onUpdate:H}){this.from=this.value=J,this.to=Q,this.lerp=$,this.duration=Z,this.easing=W,this.currentTime=0,this.isRunning=!0,K?.(),this.onUpdate=H}};function yW(J,Q){let $;return function(...Z){clearTimeout($),$=setTimeout(()=>{$=void 0,J.apply(this,Z)},Q)}}var fW=class{width=0;height=0;scrollHeight=0;scrollWidth=0;debouncedResize;wrapperResizeObserver;contentResizeObserver;constructor(J,Q,{autoResize:$=!0,debounce:Z=250}={}){if(this.wrapper=J,this.content=Q,$){if(this.debouncedResize=yW(this.resize,Z),this.wrapper instanceof Window)window.addEventListener("resize",this.debouncedResize);else this.wrapperResizeObserver=new ResizeObserver(this.debouncedResize),this.wrapperResizeObserver.observe(this.wrapper);this.contentResizeObserver=new ResizeObserver(this.debouncedResize),this.contentResizeObserver.observe(this.content)}this.resize()}destroy(){if(this.wrapperResizeObserver?.disconnect(),this.contentResizeObserver?.disconnect(),this.wrapper===window&&this.debouncedResize)window.removeEventListener("resize",this.debouncedResize)}resize=()=>{this.onWrapperResize(),this.onContentResize()};onWrapperResize=()=>{if(this.wrapper instanceof Window)this.width=window.innerWidth,this.height=window.innerHeight;else this.width=this.wrapper.clientWidth,this.height=this.wrapper.clientHeight};onContentResize=()=>{if(this.wrapper instanceof Window)this.scrollHeight=this.content.scrollHeight,this.scrollWidth=this.content.scrollWidth;else this.scrollHeight=this.wrapper.scrollHeight,this.scrollWidth=this.wrapper.scrollWidth};get limit(){return{x:this.scrollWidth-this.width,y:this.scrollHeight-this.height}}},E$=class{events={};emit(J,...Q){let $=this.events[J]||[];for(let Z=0,W=$.length;Z<W;Z++)$[Z]?.(...Q)}on(J,Q){if(this.events[J])this.events[J].push(Q);else this.events[J]=[Q];return()=>{this.events[J]=this.events[J]?.filter(($)=>Q!==$)}}off(J,Q){this.events[J]=this.events[J]?.filter(($)=>Q!==$)}destroy(){this.events={}}},vW=16.666666666666668,O9={passive:!1};function X$(J,Q){if(J===1)return vW;if(J===2)return Q;return 1}var bW=class{touchStart={x:0,y:0};lastDelta={x:0,y:0};window={width:0,height:0};emitter=new E$;constructor(J,Q={wheelMultiplier:1,touchMultiplier:1}){this.element=J,this.options=Q,window.addEventListener("resize",this.onWindowResize),this.onWindowResize(),this.element.addEventListener("wheel",this.onWheel,O9),this.element.addEventListener("touchstart",this.onTouchStart,O9),this.element.addEventListener("touchmove",this.onTouchMove,O9),this.element.addEventListener("touchend",this.onTouchEnd,O9)}on(J,Q){return this.emitter.on(J,Q)}destroy(){this.emitter.destroy(),window.removeEventListener("resize",this.onWindowResize),this.element.removeEventListener("wheel",this.onWheel,O9),this.element.removeEventListener("touchstart",this.onTouchStart,O9),this.element.removeEventListener("touchmove",this.onTouchMove,O9),this.element.removeEventListener("touchend",this.onTouchEnd,O9)}onTouchStart=(J)=>{let{clientX:Q,clientY:$}=J.targetTouches?J.targetTouches[0]:J;this.touchStart.x=Q,this.touchStart.y=$,this.lastDelta={x:0,y:0},this.emitter.emit("scroll",{deltaX:0,deltaY:0,event:J})};onTouchMove=(J)=>{let{clientX:Q,clientY:$}=J.targetTouches?J.targetTouches[0]:J,Z=-(Q-this.touchStart.x)*this.options.touchMultiplier,W=-($-this.touchStart.y)*this.options.touchMultiplier;this.touchStart.x=Q,this.touchStart.y=$,this.lastDelta={x:Z,y:W},this.emitter.emit("scroll",{deltaX:Z,deltaY:W,event:J})};onTouchEnd=(J)=>{this.emitter.emit("scroll",{deltaX:this.lastDelta.x,deltaY:this.lastDelta.y,event:J})};onWheel=(J)=>{let{deltaX:Q,deltaY:$,deltaMode:Z}=J,W=X$(Z,this.window.width),K=X$(Z,this.window.height);Q*=W,$*=K,Q*=this.options.wheelMultiplier,$*=this.options.wheelMultiplier,this.emitter.emit("scroll",{deltaX:Q,deltaY:$,event:J})};onWindowResize=()=>{this.window={width:window.innerWidth,height:window.innerHeight}}},U$=(J)=>Math.min(1,1.001-2**(-10*J)),N$=class{_isScrolling=!1;_isStopped=!1;_isLocked=!1;_preventNextNativeScrollEvent=!1;_resetVelocityTimeout=null;_rafId=null;_isDraggingSelection=!1;isTouching;isIos;time=0;userData={};lastVelocity=0;velocity=0;direction=0;options;targetScroll;animatedScroll;animate=new jW;emitter=new E$;dimensions;virtualScroll;constructor({wrapper:J=window,content:Q=document.documentElement,eventsTarget:$=J,smoothWheel:Z=!0,syncTouch:W=!1,syncTouchLerp:K=0.075,touchInertiaExponent:H=1.7,duration:Y,easing:X,lerp:U=0.1,infinite:E=!1,orientation:N="vertical",gestureOrientation:G=N==="horizontal"?"both":"vertical",touchMultiplier:D=1,wheelMultiplier:M=1,autoResize:z=!0,prevent:F,virtualScroll:q,overscroll:_=!0,autoRaf:w=!1,anchors:V=!1,autoToggle:A=!1,allowNestedScroll:I=!1,__experimental__naiveDimensions:P=!1,naiveDimensions:O=P,stopInertiaOnNavigate:B=!1}={}){if(window.lenisVersion=Y$,!window.lenis)window.lenis={};if(window.lenis.version=Y$,N==="horizontal")window.lenis.horizontal=!0;if(W===!0)window.lenis.touch=!0;if(this.isIos=/(iPad|iPhone|iPod)/g.test(navigator.userAgent),!J||J===document.documentElement)J=window;if(typeof Y==="number"&&typeof X!=="function")X=U$;else if(typeof X==="function"&&typeof Y!=="number")Y=1;if(this.options={wrapper:J,content:Q,eventsTarget:$,smoothWheel:Z,syncTouch:W,syncTouchLerp:K,touchInertiaExponent:H,duration:Y,easing:X,lerp:U,infinite:E,gestureOrientation:G,orientation:N,touchMultiplier:D,wheelMultiplier:M,autoResize:z,prevent:F,virtualScroll:q,overscroll:_,autoRaf:w,anchors:V,autoToggle:A,allowNestedScroll:I,naiveDimensions:O,stopInertiaOnNavigate:B},this.dimensions=new fW(J,Q,{autoResize:z}),this.updateClassName(),this.targetScroll=this.animatedScroll=this.actualScroll,this.options.wrapper.addEventListener("scroll",this.onNativeScroll),this.options.wrapper.addEventListener("scrollend",this.onScrollEnd,{capture:!0}),this.options.anchors||this.options.stopInertiaOnNavigate)this.options.wrapper.addEventListener("click",this.onClick);if(this.options.wrapper.addEventListener("pointerdown",this.onPointerDown),this.virtualScroll=new bW($,{touchMultiplier:D,wheelMultiplier:M}),this.virtualScroll.on("scroll",this.onVirtualScroll),this.options.autoToggle)this.checkOverflow(),this.rootElement.addEventListener("transitionend",this.onTransitionEnd);if(this.options.autoRaf)this._rafId=requestAnimationFrame(this.raf)}destroy(){if(this.emitter.destroy(),this.options.wrapper.removeEventListener("scroll",this.onNativeScroll),this.options.wrapper.removeEventListener("scrollend",this.onScrollEnd,{capture:!0}),this.options.wrapper.removeEventListener("pointerdown",this.onPointerDown),this.options.anchors||this.options.stopInertiaOnNavigate)this.options.wrapper.removeEventListener("click",this.onClick);if(this.virtualScroll.destroy(),this.dimensions.destroy(),this.cleanUpClassName(),this._rafId)cancelAnimationFrame(this._rafId)}on(J,Q){return this.emitter.on(J,Q)}off(J,Q){return this.emitter.off(J,Q)}onScrollEnd=(J)=>{if(!(J instanceof CustomEvent)){if(this.isScrolling==="smooth"||this.isScrolling===!1)J.stopPropagation()}};dispatchScrollendEvent=()=>{this.options.wrapper.dispatchEvent(new CustomEvent("scrollend",{bubbles:this.options.wrapper===window,detail:{lenisScrollEnd:!0}}))};get overflow(){let J=this.isHorizontal?"overflow-x":"overflow-y";return getComputedStyle(this.rootElement)[J]}checkOverflow(){if(["hidden","clip"].includes(this.overflow))this.internalStop();else this.internalStart()}onTransitionEnd=(J)=>{if(J.propertyName?.includes("overflow")&&J.target===this.rootElement)this.checkOverflow()};setScroll(J){if(this.isHorizontal)this.options.wrapper.scrollTo({left:J,behavior:"instant"});else this.options.wrapper.scrollTo({top:J,behavior:"instant"})}onClick=(J)=>{let Q=J.composedPath().filter((Z)=>Z instanceof HTMLAnchorElement&&Z.href).map((Z)=>new URL(Z.href)),$=new URL(window.location.href);if(this.options.anchors){let Z=Q.find((W)=>$.host===W.host&&$.pathname===W.pathname&&W.hash);if(Z){let W=typeof this.options.anchors==="object"&&this.options.anchors?this.options.anchors:void 0,K=decodeURIComponent(Z.hash);this.scrollTo(K,W);return}}if(this.options.stopInertiaOnNavigate){if(Q.some((Z)=>$.host===Z.host&&$.pathname!==Z.pathname)){this.reset();return}}};onPointerDown=(J)=>{if(J.button===1)this.reset()};isTouchOnSelectionHandle(J){let Q=window.getSelection();if(!Q||Q.isCollapsed||Q.rangeCount===0)return!1;let $=J.targetTouches[0]??J.changedTouches[0];if(!$)return!1;let Z=Q.getRangeAt(0).getClientRects();if(Z.length===0)return!1;let W=Z[0],K=Z[Z.length-1],H=40,Y=Math.hypot($.clientX-W.left,$.clientY-W.top)<=H,X=Math.hypot($.clientX-K.right,$.clientY-K.bottom)<=H;return Y||X}onVirtualScroll=(J)=>{if(typeof this.options.virtualScroll==="function"&&this.options.virtualScroll(J)===!1)return;let{deltaX:Q,deltaY:$,event:Z}=J;if(this.emitter.emit("virtual-scroll",{deltaX:Q,deltaY:$,event:Z}),Z.ctrlKey)return;if(Z.lenisStopPropagation)return;let W=Z.type.includes("touch"),K=Z.type.includes("wheel");if(W&&this.isIos){if(Z.type==="touchstart")this._isDraggingSelection=this.isTouchOnSelectionHandle(Z);if(this._isDraggingSelection){if(Z.type==="touchend")this._isDraggingSelection=!1;return}}this.isTouching=Z.type==="touchstart"||Z.type==="touchmove";let H=Q===0&&$===0;if(this.options.syncTouch&&W&&Z.type==="touchstart"&&H&&!this.isStopped&&!this.isLocked){this.reset();return}let Y=this.options.gestureOrientation==="vertical"&&$===0||this.options.gestureOrientation==="horizontal"&&Q===0;if(H||Y)return;let X=Z.composedPath();X=X.slice(0,X.indexOf(this.rootElement));let U=this.options.prevent,E=Math.abs(Q)>=Math.abs($)?"horizontal":"vertical";if(X.find((M)=>M instanceof HTMLElement&&(typeof U==="function"&&U?.(M)||M.hasAttribute?.("data-lenis-prevent")||E==="vertical"&&M.hasAttribute?.("data-lenis-prevent-vertical")||E==="horizontal"&&M.hasAttribute?.("data-lenis-prevent-horizontal")||W&&M.hasAttribute?.("data-lenis-prevent-touch")||K&&M.hasAttribute?.("data-lenis-prevent-wheel")||this.options.allowNestedScroll&&this.hasNestedScroll(M,{deltaX:Q,deltaY:$}))))return;if(this.isStopped||this.isLocked){if(Z.cancelable)Z.preventDefault();return}if(!(this.options.syncTouch&&W||this.options.smoothWheel&&K)){this.isScrolling="native",this.animate.stop(),Z.lenisStopPropagation=!0;return}let N=$;if(this.options.gestureOrientation==="both")N=Math.abs($)>Math.abs(Q)?$:Q;else if(this.options.gestureOrientation==="horizontal")N=Q;if(!this.options.overscroll||this.options.infinite||this.options.wrapper!==window&&this.limit>0&&(this.animatedScroll>0&&this.animatedScroll<this.limit||this.animatedScroll===0&&$>0||this.animatedScroll===this.limit&&$<0))Z.lenisStopPropagation=!0;if(Z.cancelable)Z.preventDefault();let G=W&&this.options.syncTouch,D=W&&Z.type==="touchend";if(D)N=Math.sign(N)*Math.abs(this.velocity)**this.options.touchInertiaExponent;this.scrollTo(this.targetScroll+N,{programmatic:!1,...G?{lerp:D?this.options.syncTouchLerp:1}:{lerp:this.options.lerp,duration:this.options.duration,easing:this.options.easing}})};resize(){this.dimensions.resize(),this.animatedScroll=this.targetScroll=this.actualScroll,this.emit()}emit(){this.emitter.emit("scroll",this)}onNativeScroll=()=>{if(this._resetVelocityTimeout!==null)clearTimeout(this._resetVelocityTimeout),this._resetVelocityTimeout=null;if(this._preventNextNativeScrollEvent){this._preventNextNativeScrollEvent=!1;return}if(this.isScrolling===!1||this.isScrolling==="native"){let J=this.animatedScroll;if(this.animatedScroll=this.targetScroll=this.actualScroll,this.lastVelocity=this.velocity,this.velocity=this.animatedScroll-J,this.direction=Math.sign(this.animatedScroll-J),!this.isStopped)this.isScrolling="native";if(this.emit(),this.velocity!==0)this._resetVelocityTimeout=setTimeout(()=>{this.lastVelocity=this.velocity,this.velocity=0,this.isScrolling=!1,this.emit()},400)}};reset(){this.isLocked=!1,this.isScrolling=!1,this.animatedScroll=this.targetScroll=this.actualScroll,this.lastVelocity=this.velocity=0,this.animate.stop()}start(){if(!this.isStopped)return;if(this.options.autoToggle){this.rootElement.style.removeProperty("overflow");return}this.internalStart()}internalStart(){if(!this.isStopped)return;this.reset(),this.isStopped=!1,this.emit()}stop(){if(this.isStopped)return;if(this.options.autoToggle){this.rootElement.style.setProperty("overflow","clip");return}this.internalStop()}internalStop(){if(this.isStopped)return;this.reset(),this.isStopped=!0,this.emit()}raf=(J)=>{let Q=J-(this.time||J);if(this.time=J,this.animate.advance(Q*0.001),this.options.autoRaf)this._rafId=requestAnimationFrame(this.raf)};scrollTo(J,{offset:Q=0,immediate:$=!1,lock:Z=!1,programmatic:W=!0,lerp:K=W?this.options.lerp:void 0,duration:H=W?this.options.duration:void 0,easing:Y=W?this.options.easing:void 0,onStart:X,onComplete:U,force:E=!1,userData:N}={}){if((this.isStopped||this.isLocked)&&!E)return;let G=J,D=Q;if(typeof G==="string"&&["top","left","start","#"].includes(G))G=0;else if(typeof G==="string"&&["bottom","right","end"].includes(G))G=this.limit;else{let M=null;if(typeof G==="string"){if(M=G.startsWith("#")?document.getElementById(G.slice(1)):document.querySelector(G),!M)if(G==="#top")G=0;else console.warn("Lenis: Target not found",G)}else if(G instanceof HTMLElement&&G?.nodeType)M=G;if(M){if(this.options.wrapper!==window){let V=this.rootElement.getBoundingClientRect();D-=this.isHorizontal?V.left:V.top}let z=M.getBoundingClientRect(),F=getComputedStyle(M),q=this.isHorizontal?Number.parseFloat(F.scrollMarginLeft):Number.parseFloat(F.scrollMarginTop),_=getComputedStyle(this.rootElement),w=this.isHorizontal?Number.parseFloat(_.scrollPaddingLeft):Number.parseFloat(_.scrollPaddingTop);G=(this.isHorizontal?z.left:z.top)+this.animatedScroll-(Number.isNaN(q)?0:q)-(Number.isNaN(w)?0:w)}}if(typeof G!=="number")return;if(G+=D,this.options.infinite){if(W){this.targetScroll=this.animatedScroll=this.scroll;let M=G-this.animatedScroll;if(M>this.limit/2)G-=this.limit;else if(M<-this.limit/2)G+=this.limit}}else G=G$(0,G,this.limit);if(G===this.targetScroll){X?.(this),U?.(this);return}if(this.userData=N??{},$){this.animatedScroll=this.targetScroll=G,this.setScroll(this.scroll),this.reset(),this.preventNextNativeScrollEvent(),this.emit(),U?.(this),this.userData={},requestAnimationFrame(()=>{this.dispatchScrollendEvent()});return}if(!W)this.targetScroll=G;if(typeof H==="number"&&typeof Y!=="function")Y=U$;else if(typeof Y==="function"&&typeof H!=="number")H=1;this.animate.fromTo(this.animatedScroll,G,{duration:H,easing:Y,lerp:K,onStart:()=>{if(Z)this.isLocked=!0;this.isScrolling="smooth",X?.(this)},onUpdate:(M,z)=>{if(this.isScrolling="smooth",this.lastVelocity=this.velocity,this.velocity=M-this.animatedScroll,this.direction=Math.sign(this.velocity),this.animatedScroll=M,this.setScroll(this.scroll),W)this.targetScroll=M;if(!z)this.emit();if(z)this.reset(),this.emit(),U?.(this),this.userData={},requestAnimationFrame(()=>{this.dispatchScrollendEvent()}),this.preventNextNativeScrollEvent()}})}preventNextNativeScrollEvent(){this._preventNextNativeScrollEvent=!0,requestAnimationFrame(()=>{this._preventNextNativeScrollEvent=!1})}hasNestedScroll(J,{deltaX:Q,deltaY:$}){let Z=Date.now();if(!J._lenis)J._lenis={};let W=J._lenis,K,H,Y,X,U,E,N,G,D,M;if(Z-(W.time??0)>2000){W.time=Date.now();let I=window.getComputedStyle(J);if(W.computedStyle=I,K=["auto","overlay","scroll"].includes(I.overflowX),H=["auto","overlay","scroll"].includes(I.overflowY),U=["auto"].includes(I.overscrollBehaviorX),E=["auto"].includes(I.overscrollBehaviorY),W.hasOverflowX=K,W.hasOverflowY=H,!(K||H))return!1;N=J.scrollWidth,G=J.scrollHeight,D=J.clientWidth,M=J.clientHeight,Y=N>D,X=G>M,W.isScrollableX=Y,W.isScrollableY=X,W.scrollWidth=N,W.scrollHeight=G,W.clientWidth=D,W.clientHeight=M,W.hasOverscrollBehaviorX=U,W.hasOverscrollBehaviorY=E}else Y=W.isScrollableX,X=W.isScrollableY,K=W.hasOverflowX,H=W.hasOverflowY,N=W.scrollWidth,G=W.scrollHeight,D=W.clientWidth,M=W.clientHeight,U=W.hasOverscrollBehaviorX,E=W.hasOverscrollBehaviorY;if(!(K&&Y||H&&X))return!1;let z=Math.abs(Q)>=Math.abs($)?"horizontal":"vertical",F,q,_,w,V,A;if(z==="horizontal")F=Math.round(J.scrollLeft),q=N-D,_=Q,w=K,V=Y,A=U;else if(z==="vertical")F=Math.round(J.scrollTop),q=G-M,_=$,w=H,V=X,A=E;else return!1;if(!A&&(F>=q||F<=0))return!0;return(_>0?F<q:F>0)&&w&&V}get rootElement(){return this.options.wrapper===window?document.documentElement:this.options.wrapper}get limit(){if(this.options.naiveDimensions){if(this.isHorizontal)return this.rootElement.scrollWidth-this.rootElement.clientWidth;return this.rootElement.scrollHeight-this.rootElement.clientHeight}return this.dimensions.limit[this.isHorizontal?"x":"y"]}get isHorizontal(){return this.options.orientation==="horizontal"}get actualScroll(){let J=this.options.wrapper;return this.isHorizontal?J.scrollX??J.scrollLeft:J.scrollY??J.scrollTop}get scroll(){return this.options.infinite?SW(this.animatedScroll,this.limit):this.animatedScroll}get progress(){return this.limit===0?1:this.scroll/this.limit}get isScrolling(){return this._isScrolling}set isScrolling(J){if(this._isScrolling!==J)this._isScrolling=J,this.updateClassName()}get isStopped(){return this._isStopped}set isStopped(J){if(this._isStopped!==J)this._isStopped=J,this.updateClassName()}get isLocked(){return this._isLocked}set isLocked(J){if(this._isLocked!==J)this._isLocked=J,this.updateClassName()}get isSmooth(){return this.isScrolling==="smooth"}get className(){let J="lenis";if(this.options.autoToggle)J+=" lenis-autoToggle";if(this.isStopped)J+=" lenis-stopped";if(this.isLocked)J+=" lenis-locked";if(this.isScrolling)J+=" lenis-scrolling";if(this.isScrolling==="smooth")J+=" lenis-smooth";return J}updateClassName(){this.cleanUpClassName(),this.className.split(" ").forEach((J)=>{this.rootElement.classList.add(J)})}cleanUpClassName(){for(let J of Array.from(this.rootElement.classList))if(J==="lenis"||J.startsWith("lenis-"))this.rootElement.classList.remove(J)}};var y$="185";var f$=0,D7=1,v$=2;var w8=1,b$=2,E8=3,N8=0,CJ=1,rJ=2,tJ=0,C8=1,R7=2,O7=3,k7=4,h$=5;var q8=100,x$=101,g$=102,p$=103,m$=104,d$=200,l$=201,u$=202,c$=203,n$=204,s$=205,i$=206,o$=207,a$=208,r$=209,t$=210,e$=211,JZ=212,QZ=213,$Z=214,ZZ=0,WZ=1,KZ=2,M7=3,HZ=4,YZ=5,XZ=6,UZ=7,GZ=0,EZ=1,NZ=2,cJ=0,L7=1,V7=2,B7=3,z7=4,I7=5,A7=6,w7=7;var F8=301,b9=302,E6=303,N6=304,_8=306,qZ=1000,q6=1001,FZ=1002,w9=1003,DZ=1004;var P8=1005;var _J=1006,F6=1007;var h9=1008;var nJ=1009,RZ=1010,OZ=1011,T8=1012,C7=1013,C9=1014,G9=1015,E9=1016,_7=1017,P7=1018,D8=1020,kZ=35902,MZ=35899,LZ=1021,VZ=1022,eJ=1023,x9=1026,g9=1027,BZ=1028,T7=1029,p9=1030,S7=1031;var j7=1033,D6=33776,R6=33777,O6=33778,k6=33779,y7=35840,f7=35841,v7=35842,b7=35843,h7=36196,x7=37492,g7=37496,p7=37488,m7=37489,M6=37490,d7=37491,l7=37808,u7=37809,c7=37810,n7=37811,s7=37812,i7=37813,o7=37814,a7=37815,r7=37816,t7=37817,e7=37818,JQ=37819,QQ=37820,$Q=37821,ZQ=36492,WQ=36494,KQ=36495,HQ=36283,YQ=36284,L6=36285,XQ=36286;var UQ=0,zZ=1,m9="",IZ="srgb",GQ="srgb-linear",EQ="linear",r0="srgb";var AZ=512,wZ=513,CZ=514,V6=515,_Z=516,PZ=517,B6=518,TZ=519;var NQ="300 es",qQ=2000;function hW(J){for(let Q=J.length-1;Q>=0;--Q)if(J[Q]>=65535)return!0;return!1}function xW(J){return ArrayBuffer.isView(J)&&!(J instanceof DataView)}function A8(J){return document.createElementNS("http://www.w3.org/1999/xhtml",J)}function SZ(){let J=A8("canvas");return J.style.display="block",J}var q$={},G8=null;function FQ(...J){let Q="THREE."+J.shift();if(G8)G8("log",Q,...J);else console.log(Q,...J)}function jZ(J){let Q=J[0];if(typeof Q==="string"&&Q.startsWith("TSL:")){let $=J[1];if($&&$.isStackTrace)J[0]+=" "+$.getLocation();else J[1]='Stack trace not available. Enable "THREE.Node.captureStackTrace" to capture stack traces.'}return J}function C0(...J){J=jZ(J);let Q="THREE."+J.shift();if(G8)G8("warn",Q,...J);else{let $=J[0];if($&&$.isStackTrace)console.warn($.getError(Q));else console.warn(Q,...J)}}function _0(...J){J=jZ(J);let Q="THREE."+J.shift();if(G8)G8("error",Q,...J);else{let $=J[0];if($&&$.isStackTrace)console.error($.getError(Q));else console.error(Q,...J)}}function v9(...J){let Q=J.join(" ");if(Q in q$)return;q$[Q]=!0,C0(...J)}function yZ(J,Q,$){return new Promise(function(Z,W){function K(){switch(J.clientWaitSync(Q,J.SYNC_FLUSH_COMMANDS_BIT,0)){case J.WAIT_FAILED:W();break;case J.TIMEOUT_EXPIRED:setTimeout(K,$);break;default:Z()}}setTimeout(K,$)})}var fZ={[0]:1,[2]:6,[4]:7,[3]:5,[1]:0,[6]:2,[7]:4,[5]:3};class N9{addEventListener(J,Q){if(this._listeners===void 0)this._listeners={};let $=this._listeners;if($[J]===void 0)$[J]=[];if($[J].indexOf(Q)===-1)$[J].push(Q)}hasEventListener(J,Q){let $=this._listeners;if($===void 0)return!1;return $[J]!==void 0&&$[J].indexOf(Q)!==-1}removeEventListener(J,Q){let $=this._listeners;if($===void 0)return;let Z=$[J];if(Z!==void 0){let W=Z.indexOf(Q);if(W!==-1)Z.splice(W,1)}}dispatchEvent(J){let Q=this._listeners;if(Q===void 0)return;let $=Q[J.type];if($!==void 0){J.target=this;let Z=$.slice(0);for(let W=0,K=Z.length;W<K;W++)Z[W].call(this,J);J.target=null}}}var MJ=["00","01","02","03","04","05","06","07","08","09","0a","0b","0c","0d","0e","0f","10","11","12","13","14","15","16","17","18","19","1a","1b","1c","1d","1e","1f","20","21","22","23","24","25","26","27","28","29","2a","2b","2c","2d","2e","2f","30","31","32","33","34","35","36","37","38","39","3a","3b","3c","3d","3e","3f","40","41","42","43","44","45","46","47","48","49","4a","4b","4c","4d","4e","4f","50","51","52","53","54","55","56","57","58","59","5a","5b","5c","5d","5e","5f","60","61","62","63","64","65","66","67","68","69","6a","6b","6c","6d","6e","6f","70","71","72","73","74","75","76","77","78","79","7a","7b","7c","7d","7e","7f","80","81","82","83","84","85","86","87","88","89","8a","8b","8c","8d","8e","8f","90","91","92","93","94","95","96","97","98","99","9a","9b","9c","9d","9e","9f","a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","aa","ab","ac","ad","ae","af","b0","b1","b2","b3","b4","b5","b6","b7","b8","b9","ba","bb","bc","bd","be","bf","c0","c1","c2","c3","c4","c5","c6","c7","c8","c9","ca","cb","cc","cd","ce","cf","d0","d1","d2","d3","d4","d5","d6","d7","d8","d9","da","db","dc","dd","de","df","e0","e1","e2","e3","e4","e5","e6","e7","e8","e9","ea","eb","ec","ed","ee","ef","f0","f1","f2","f3","f4","f5","f6","f7","f8","f9","fa","fb","fc","fd","fe","ff"];var c6=Math.PI/180,G6=180/Math.PI;function S8(){let J=Math.random()*4294967295|0,Q=Math.random()*4294967295|0,$=Math.random()*4294967295|0,Z=Math.random()*4294967295|0;return(MJ[J&255]+MJ[J>>8&255]+MJ[J>>16&255]+MJ[J>>24&255]+"-"+MJ[Q&255]+MJ[Q>>8&255]+"-"+MJ[Q>>16&15|64]+MJ[Q>>24&255]+"-"+MJ[$&63|128]+MJ[$>>8&255]+"-"+MJ[$>>16&255]+MJ[$>>24&255]+MJ[Z&255]+MJ[Z>>8&255]+MJ[Z>>16&255]+MJ[Z>>24&255]).toLowerCase()}function x0(J,Q,$){return Math.max(Q,Math.min($,J))}function gW(J,Q){return(J%Q+Q)%Q}function n6(J,Q,$){return(1-$)*J+$*Q}function L8(J,Q){switch(Q.constructor){case Float32Array:return J;case Uint32Array:return J/4294967295;case Uint16Array:return J/65535;case Uint8Array:return J/255;case Int32Array:return Math.max(J/2147483647,-1);case Int16Array:return Math.max(J/32767,-1);case Int8Array:return Math.max(J/127,-1);default:throw Error("THREE.MathUtils: Invalid component type.")}}function AJ(J,Q){switch(Q.constructor){case Float32Array:return J;case Uint32Array:return Math.round(J*4294967295);case Uint16Array:return Math.round(J*65535);case Uint8Array:return Math.round(J*255);case Int32Array:return Math.round(J*2147483647);case Int16Array:return Math.round(J*32767);case Int8Array:return Math.round(J*127);default:throw Error("THREE.MathUtils: Invalid component type.")}}class u0{static{u0.prototype.isVector2=!0}constructor(J=0,Q=0){this.x=J,this.y=Q}get width(){return this.x}set width(J){this.x=J}get height(){return this.y}set height(J){this.y=J}set(J,Q){return this.x=J,this.y=Q,this}setScalar(J){return this.x=J,this.y=J,this}setX(J){return this.x=J,this}setY(J){return this.y=J,this}setComponent(J,Q){switch(J){case 0:this.x=Q;break;case 1:this.y=Q;break;default:throw Error("THREE.Vector2: index is out of range: "+J)}return this}getComponent(J){switch(J){case 0:return this.x;case 1:return this.y;default:throw Error("THREE.Vector2: index is out of range: "+J)}}clone(){return new this.constructor(this.x,this.y)}copy(J){return this.x=J.x,this.y=J.y,this}add(J){return this.x+=J.x,this.y+=J.y,this}addScalar(J){return this.x+=J,this.y+=J,this}addVectors(J,Q){return this.x=J.x+Q.x,this.y=J.y+Q.y,this}addScaledVector(J,Q){return this.x+=J.x*Q,this.y+=J.y*Q,this}sub(J){return this.x-=J.x,this.y-=J.y,this}subScalar(J){return this.x-=J,this.y-=J,this}subVectors(J,Q){return this.x=J.x-Q.x,this.y=J.y-Q.y,this}multiply(J){return this.x*=J.x,this.y*=J.y,this}multiplyScalar(J){return this.x*=J,this.y*=J,this}divide(J){return this.x/=J.x,this.y/=J.y,this}divideScalar(J){return this.multiplyScalar(1/J)}applyMatrix3(J){let Q=this.x,$=this.y,Z=J.elements;return this.x=Z[0]*Q+Z[3]*$+Z[6],this.y=Z[1]*Q+Z[4]*$+Z[7],this}min(J){return this.x=Math.min(this.x,J.x),this.y=Math.min(this.y,J.y),this}max(J){return this.x=Math.max(this.x,J.x),this.y=Math.max(this.y,J.y),this}clamp(J,Q){return this.x=x0(this.x,J.x,Q.x),this.y=x0(this.y,J.y,Q.y),this}clampScalar(J,Q){return this.x=x0(this.x,J,Q),this.y=x0(this.y,J,Q),this}clampLength(J,Q){let $=this.length();return this.divideScalar($||1).multiplyScalar(x0($,J,Q))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this}negate(){return this.x=-this.x,this.y=-this.y,this}dot(J){return this.x*J.x+this.y*J.y}cross(J){return this.x*J.y-this.y*J.x}lengthSq(){return this.x*this.x+this.y*this.y}length(){return Math.sqrt(this.x*this.x+this.y*this.y)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)}normalize(){return this.divideScalar(this.length()||1)}angle(){return Math.atan2(-this.y,-this.x)+Math.PI}angleTo(J){let Q=Math.sqrt(this.lengthSq()*J.lengthSq());if(Q===0)return Math.PI/2;let $=this.dot(J)/Q;return Math.acos(x0($,-1,1))}distanceTo(J){return Math.sqrt(this.distanceToSquared(J))}distanceToSquared(J){let Q=this.x-J.x,$=this.y-J.y;return Q*Q+$*$}manhattanDistanceTo(J){return Math.abs(this.x-J.x)+Math.abs(this.y-J.y)}setLength(J){return this.normalize().multiplyScalar(J)}lerp(J,Q){return this.x+=(J.x-this.x)*Q,this.y+=(J.y-this.y)*Q,this}lerpVectors(J,Q,$){return this.x=J.x+(Q.x-J.x)*$,this.y=J.y+(Q.y-J.y)*$,this}equals(J){return J.x===this.x&&J.y===this.y}fromArray(J,Q=0){return this.x=J[Q],this.y=J[Q+1],this}toArray(J=[],Q=0){return J[Q]=this.x,J[Q+1]=this.y,J}fromBufferAttribute(J,Q){return this.x=J.getX(Q),this.y=J.getY(Q),this}rotateAround(J,Q){let $=Math.cos(Q),Z=Math.sin(Q),W=this.x-J.x,K=this.y-J.y;return this.x=W*$-K*Z+J.x,this.y=W*Z+K*$+J.y,this}random(){return this.x=Math.random(),this.y=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y}}class q9{constructor(J=0,Q=0,$=0,Z=1){this.isQuaternion=!0,this._x=J,this._y=Q,this._z=$,this._w=Z}static slerpFlat(J,Q,$,Z,W,K,H){let Y=$[Z+0],X=$[Z+1],U=$[Z+2],E=$[Z+3],N=W[K+0],G=W[K+1],D=W[K+2],M=W[K+3];if(E!==M||Y!==N||X!==G||U!==D){let z=Y*N+X*G+U*D+E*M;if(z<0)N=-N,G=-G,D=-D,M=-M,z=-z;let F=1-H;if(z<0.9995){let q=Math.acos(z),_=Math.sin(q);F=Math.sin(F*q)/_,H=Math.sin(H*q)/_,Y=Y*F+N*H,X=X*F+G*H,U=U*F+D*H,E=E*F+M*H}else{Y=Y*F+N*H,X=X*F+G*H,U=U*F+D*H,E=E*F+M*H;let q=1/Math.sqrt(Y*Y+X*X+U*U+E*E);Y*=q,X*=q,U*=q,E*=q}}J[Q]=Y,J[Q+1]=X,J[Q+2]=U,J[Q+3]=E}static multiplyQuaternionsFlat(J,Q,$,Z,W,K){let H=$[Z],Y=$[Z+1],X=$[Z+2],U=$[Z+3],E=W[K],N=W[K+1],G=W[K+2],D=W[K+3];return J[Q]=H*D+U*E+Y*G-X*N,J[Q+1]=Y*D+U*N+X*E-H*G,J[Q+2]=X*D+U*G+H*N-Y*E,J[Q+3]=U*D-H*E-Y*N-X*G,J}get x(){return this._x}set x(J){this._x=J,this._onChangeCallback()}get y(){return this._y}set y(J){this._y=J,this._onChangeCallback()}get z(){return this._z}set z(J){this._z=J,this._onChangeCallback()}get w(){return this._w}set w(J){this._w=J,this._onChangeCallback()}set(J,Q,$,Z){return this._x=J,this._y=Q,this._z=$,this._w=Z,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._w)}copy(J){return this._x=J.x,this._y=J.y,this._z=J.z,this._w=J.w,this._onChangeCallback(),this}setFromEuler(J,Q=!0){let{_x:$,_y:Z,_z:W,_order:K}=J,H=Math.cos,Y=Math.sin,X=H($/2),U=H(Z/2),E=H(W/2),N=Y($/2),G=Y(Z/2),D=Y(W/2);switch(K){case"XYZ":this._x=N*U*E+X*G*D,this._y=X*G*E-N*U*D,this._z=X*U*D+N*G*E,this._w=X*U*E-N*G*D;break;case"YXZ":this._x=N*U*E+X*G*D,this._y=X*G*E-N*U*D,this._z=X*U*D-N*G*E,this._w=X*U*E+N*G*D;break;case"ZXY":this._x=N*U*E-X*G*D,this._y=X*G*E+N*U*D,this._z=X*U*D+N*G*E,this._w=X*U*E-N*G*D;break;case"ZYX":this._x=N*U*E-X*G*D,this._y=X*G*E+N*U*D,this._z=X*U*D-N*G*E,this._w=X*U*E+N*G*D;break;case"YZX":this._x=N*U*E+X*G*D,this._y=X*G*E+N*U*D,this._z=X*U*D-N*G*E,this._w=X*U*E-N*G*D;break;case"XZY":this._x=N*U*E-X*G*D,this._y=X*G*E-N*U*D,this._z=X*U*D+N*G*E,this._w=X*U*E+N*G*D;break;default:C0("Quaternion: .setFromEuler() encountered an unknown order: "+K)}if(Q===!0)this._onChangeCallback();return this}setFromAxisAngle(J,Q){let $=Q/2,Z=Math.sin($);return this._x=J.x*Z,this._y=J.y*Z,this._z=J.z*Z,this._w=Math.cos($),this._onChangeCallback(),this}setFromRotationMatrix(J){let Q=J.elements,$=Q[0],Z=Q[4],W=Q[8],K=Q[1],H=Q[5],Y=Q[9],X=Q[2],U=Q[6],E=Q[10],N=$+H+E;if(N>0){let G=0.5/Math.sqrt(N+1);this._w=0.25/G,this._x=(U-Y)*G,this._y=(W-X)*G,this._z=(K-Z)*G}else if($>H&&$>E){let G=2*Math.sqrt(1+$-H-E);this._w=(U-Y)/G,this._x=0.25*G,this._y=(Z+K)/G,this._z=(W+X)/G}else if(H>E){let G=2*Math.sqrt(1+H-$-E);this._w=(W-X)/G,this._x=(Z+K)/G,this._y=0.25*G,this._z=(Y+U)/G}else{let G=2*Math.sqrt(1+E-$-H);this._w=(K-Z)/G,this._x=(W+X)/G,this._y=(Y+U)/G,this._z=0.25*G}return this._onChangeCallback(),this}setFromUnitVectors(J,Q){let $=J.dot(Q)+1;if($<0.00000001)if($=0,Math.abs(J.x)>Math.abs(J.z))this._x=-J.y,this._y=J.x,this._z=0,this._w=$;else this._x=0,this._y=-J.z,this._z=J.y,this._w=$;else this._x=J.y*Q.z-J.z*Q.y,this._y=J.z*Q.x-J.x*Q.z,this._z=J.x*Q.y-J.y*Q.x,this._w=$;return this.normalize()}angleTo(J){return 2*Math.acos(Math.abs(x0(this.dot(J),-1,1)))}rotateTowards(J,Q){let $=this.angleTo(J);if($===0)return this;let Z=Math.min(1,Q/$);return this.slerp(J,Z),this}identity(){return this.set(0,0,0,1)}invert(){return this.conjugate()}conjugate(){return this._x*=-1,this._y*=-1,this._z*=-1,this._onChangeCallback(),this}dot(J){return this._x*J._x+this._y*J._y+this._z*J._z+this._w*J._w}lengthSq(){return this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w}length(){return Math.sqrt(this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w)}normalize(){let J=this.length();if(J===0)this._x=0,this._y=0,this._z=0,this._w=1;else J=1/J,this._x=this._x*J,this._y=this._y*J,this._z=this._z*J,this._w=this._w*J;return this._onChangeCallback(),this}multiply(J){return this.multiplyQuaternions(this,J)}premultiply(J){return this.multiplyQuaternions(J,this)}multiplyQuaternions(J,Q){let{_x:$,_y:Z,_z:W,_w:K}=J,H=Q._x,Y=Q._y,X=Q._z,U=Q._w;return this._x=$*U+K*H+Z*X-W*Y,this._y=Z*U+K*Y+W*H-$*X,this._z=W*U+K*X+$*Y-Z*H,this._w=K*U-$*H-Z*Y-W*X,this._onChangeCallback(),this}slerp(J,Q){let{_x:$,_y:Z,_z:W,_w:K}=J,H=this.dot(J);if(H<0)$=-$,Z=-Z,W=-W,K=-K,H=-H;let Y=1-Q;if(H<0.9995){let X=Math.acos(H),U=Math.sin(X);Y=Math.sin(Y*X)/U,Q=Math.sin(Q*X)/U,this._x=this._x*Y+$*Q,this._y=this._y*Y+Z*Q,this._z=this._z*Y+W*Q,this._w=this._w*Y+K*Q,this._onChangeCallback()}else this._x=this._x*Y+$*Q,this._y=this._y*Y+Z*Q,this._z=this._z*Y+W*Q,this._w=this._w*Y+K*Q,this.normalize();return this}slerpQuaternions(J,Q,$){return this.copy(J).slerp(Q,$)}random(){let J=2*Math.PI*Math.random(),Q=2*Math.PI*Math.random(),$=Math.random(),Z=Math.sqrt(1-$),W=Math.sqrt($);return this.set(Z*Math.sin(J),Z*Math.cos(J),W*Math.sin(Q),W*Math.cos(Q))}equals(J){return J._x===this._x&&J._y===this._y&&J._z===this._z&&J._w===this._w}fromArray(J,Q=0){return this._x=J[Q],this._y=J[Q+1],this._z=J[Q+2],this._w=J[Q+3],this._onChangeCallback(),this}toArray(J=[],Q=0){return J[Q]=this._x,J[Q+1]=this._y,J[Q+2]=this._z,J[Q+3]=this._w,J}fromBufferAttribute(J,Q){return this._x=J.getX(Q),this._y=J.getY(Q),this._z=J.getZ(Q),this._w=J.getW(Q),this._onChangeCallback(),this}toJSON(){return this.toArray()}_onChange(J){return this._onChangeCallback=J,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._w}}class b{static{b.prototype.isVector3=!0}constructor(J=0,Q=0,$=0){this.x=J,this.y=Q,this.z=$}set(J,Q,$){if($===void 0)$=this.z;return this.x=J,this.y=Q,this.z=$,this}setScalar(J){return this.x=J,this.y=J,this.z=J,this}setX(J){return this.x=J,this}setY(J){return this.y=J,this}setZ(J){return this.z=J,this}setComponent(J,Q){switch(J){case 0:this.x=Q;break;case 1:this.y=Q;break;case 2:this.z=Q;break;default:throw Error("THREE.Vector3: index is out of range: "+J)}return this}getComponent(J){switch(J){case 0:return this.x;case 1:return this.y;case 2:return this.z;default:throw Error("THREE.Vector3: index is out of range: "+J)}}clone(){return new this.constructor(this.x,this.y,this.z)}copy(J){return this.x=J.x,this.y=J.y,this.z=J.z,this}add(J){return this.x+=J.x,this.y+=J.y,this.z+=J.z,this}addScalar(J){return this.x+=J,this.y+=J,this.z+=J,this}addVectors(J,Q){return this.x=J.x+Q.x,this.y=J.y+Q.y,this.z=J.z+Q.z,this}addScaledVector(J,Q){return this.x+=J.x*Q,this.y+=J.y*Q,this.z+=J.z*Q,this}sub(J){return this.x-=J.x,this.y-=J.y,this.z-=J.z,this}subScalar(J){return this.x-=J,this.y-=J,this.z-=J,this}subVectors(J,Q){return this.x=J.x-Q.x,this.y=J.y-Q.y,this.z=J.z-Q.z,this}multiply(J){return this.x*=J.x,this.y*=J.y,this.z*=J.z,this}multiplyScalar(J){return this.x*=J,this.y*=J,this.z*=J,this}multiplyVectors(J,Q){return this.x=J.x*Q.x,this.y=J.y*Q.y,this.z=J.z*Q.z,this}applyEuler(J){return this.applyQuaternion(F$.setFromEuler(J))}applyAxisAngle(J,Q){return this.applyQuaternion(F$.setFromAxisAngle(J,Q))}applyMatrix3(J){let Q=this.x,$=this.y,Z=this.z,W=J.elements;return this.x=W[0]*Q+W[3]*$+W[6]*Z,this.y=W[1]*Q+W[4]*$+W[7]*Z,this.z=W[2]*Q+W[5]*$+W[8]*Z,this}applyNormalMatrix(J){return this.applyMatrix3(J).normalize()}applyMatrix4(J){let Q=this.x,$=this.y,Z=this.z,W=J.elements,K=1/(W[3]*Q+W[7]*$+W[11]*Z+W[15]);return this.x=(W[0]*Q+W[4]*$+W[8]*Z+W[12])*K,this.y=(W[1]*Q+W[5]*$+W[9]*Z+W[13])*K,this.z=(W[2]*Q+W[6]*$+W[10]*Z+W[14])*K,this}applyQuaternion(J){let Q=this.x,$=this.y,Z=this.z,W=J.x,K=J.y,H=J.z,Y=J.w,X=2*(K*Z-H*$),U=2*(H*Q-W*Z),E=2*(W*$-K*Q);return this.x=Q+Y*X+K*E-H*U,this.y=$+Y*U+H*X-W*E,this.z=Z+Y*E+W*U-K*X,this}project(J){return this.applyMatrix4(J.matrixWorldInverse).applyMatrix4(J.projectionMatrix)}unproject(J){return this.applyMatrix4(J.projectionMatrixInverse).applyMatrix4(J.matrixWorld)}transformDirection(J){let Q=this.x,$=this.y,Z=this.z,W=J.elements;return this.x=W[0]*Q+W[4]*$+W[8]*Z,this.y=W[1]*Q+W[5]*$+W[9]*Z,this.z=W[2]*Q+W[6]*$+W[10]*Z,this.normalize()}divide(J){return this.x/=J.x,this.y/=J.y,this.z/=J.z,this}divideScalar(J){return this.multiplyScalar(1/J)}min(J){return this.x=Math.min(this.x,J.x),this.y=Math.min(this.y,J.y),this.z=Math.min(this.z,J.z),this}max(J){return this.x=Math.max(this.x,J.x),this.y=Math.max(this.y,J.y),this.z=Math.max(this.z,J.z),this}clamp(J,Q){return this.x=x0(this.x,J.x,Q.x),this.y=x0(this.y,J.y,Q.y),this.z=x0(this.z,J.z,Q.z),this}clampScalar(J,Q){return this.x=x0(this.x,J,Q),this.y=x0(this.y,J,Q),this.z=x0(this.z,J,Q),this}clampLength(J,Q){let $=this.length();return this.divideScalar($||1).multiplyScalar(x0($,J,Q))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this}dot(J){return this.x*J.x+this.y*J.y+this.z*J.z}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)}normalize(){return this.divideScalar(this.length()||1)}setLength(J){return this.normalize().multiplyScalar(J)}lerp(J,Q){return this.x+=(J.x-this.x)*Q,this.y+=(J.y-this.y)*Q,this.z+=(J.z-this.z)*Q,this}lerpVectors(J,Q,$){return this.x=J.x+(Q.x-J.x)*$,this.y=J.y+(Q.y-J.y)*$,this.z=J.z+(Q.z-J.z)*$,this}cross(J){return this.crossVectors(this,J)}crossVectors(J,Q){let{x:$,y:Z,z:W}=J,K=Q.x,H=Q.y,Y=Q.z;return this.x=Z*Y-W*H,this.y=W*K-$*Y,this.z=$*H-Z*K,this}projectOnVector(J){let Q=J.lengthSq();if(Q===0)return this.set(0,0,0);let $=J.dot(this)/Q;return this.copy(J).multiplyScalar($)}projectOnPlane(J){return s6.copy(this).projectOnVector(J),this.sub(s6)}reflect(J){return this.sub(s6.copy(J).multiplyScalar(2*this.dot(J)))}angleTo(J){let Q=Math.sqrt(this.lengthSq()*J.lengthSq());if(Q===0)return Math.PI/2;let $=this.dot(J)/Q;return Math.acos(x0($,-1,1))}distanceTo(J){return Math.sqrt(this.distanceToSquared(J))}distanceToSquared(J){let Q=this.x-J.x,$=this.y-J.y,Z=this.z-J.z;return Q*Q+$*$+Z*Z}manhattanDistanceTo(J){return Math.abs(this.x-J.x)+Math.abs(this.y-J.y)+Math.abs(this.z-J.z)}setFromSpherical(J){return this.setFromSphericalCoords(J.radius,J.phi,J.theta)}setFromSphericalCoords(J,Q,$){let Z=Math.sin(Q)*J;return this.x=Z*Math.sin($),this.y=Math.cos(Q)*J,this.z=Z*Math.cos($),this}setFromCylindrical(J){return this.setFromCylindricalCoords(J.radius,J.theta,J.y)}setFromCylindricalCoords(J,Q,$){return this.x=J*Math.sin(Q),this.y=$,this.z=J*Math.cos(Q),this}setFromMatrixPosition(J){let Q=J.elements;return this.x=Q[12],this.y=Q[13],this.z=Q[14],this}setFromMatrixScale(J){let Q=this.setFromMatrixColumn(J,0).length(),$=this.setFromMatrixColumn(J,1).length(),Z=this.setFromMatrixColumn(J,2).length();return this.x=Q,this.y=$,this.z=Z,this}setFromMatrixColumn(J,Q){return this.fromArray(J.elements,Q*4)}setFromMatrix3Column(J,Q){return this.fromArray(J.elements,Q*3)}setFromEuler(J){return this.x=J._x,this.y=J._y,this.z=J._z,this}setFromColor(J){return this.x=J.r,this.y=J.g,this.z=J.b,this}equals(J){return J.x===this.x&&J.y===this.y&&J.z===this.z}fromArray(J,Q=0){return this.x=J[Q],this.y=J[Q+1],this.z=J[Q+2],this}toArray(J=[],Q=0){return J[Q]=this.x,J[Q+1]=this.y,J[Q+2]=this.z,J}fromBufferAttribute(J,Q){return this.x=J.getX(Q),this.y=J.getY(Q),this.z=J.getZ(Q),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this}randomDirection(){let J=Math.random()*Math.PI*2,Q=Math.random()*2-1,$=Math.sqrt(1-Q*Q);return this.x=$*Math.cos(J),this.y=Q,this.z=$*Math.sin(J),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z}}var s6=new b,F$=new q9;class P0{static{P0.prototype.isMatrix3=!0}constructor(J,Q,$,Z,W,K,H,Y,X){if(this.elements=[1,0,0,0,1,0,0,0,1],J!==void 0)this.set(J,Q,$,Z,W,K,H,Y,X)}set(J,Q,$,Z,W,K,H,Y,X){let U=this.elements;return U[0]=J,U[1]=Z,U[2]=H,U[3]=Q,U[4]=W,U[5]=Y,U[6]=$,U[7]=K,U[8]=X,this}identity(){return this.set(1,0,0,0,1,0,0,0,1),this}copy(J){let Q=this.elements,$=J.elements;return Q[0]=$[0],Q[1]=$[1],Q[2]=$[2],Q[3]=$[3],Q[4]=$[4],Q[5]=$[5],Q[6]=$[6],Q[7]=$[7],Q[8]=$[8],this}extractBasis(J,Q,$){return J.setFromMatrix3Column(this,0),Q.setFromMatrix3Column(this,1),$.setFromMatrix3Column(this,2),this}setFromMatrix4(J){let Q=J.elements;return this.set(Q[0],Q[4],Q[8],Q[1],Q[5],Q[9],Q[2],Q[6],Q[10]),this}multiply(J){return this.multiplyMatrices(this,J)}premultiply(J){return this.multiplyMatrices(J,this)}multiplyMatrices(J,Q){let $=J.elements,Z=Q.elements,W=this.elements,K=$[0],H=$[3],Y=$[6],X=$[1],U=$[4],E=$[7],N=$[2],G=$[5],D=$[8],M=Z[0],z=Z[3],F=Z[6],q=Z[1],_=Z[4],w=Z[7],V=Z[2],A=Z[5],I=Z[8];return W[0]=K*M+H*q+Y*V,W[3]=K*z+H*_+Y*A,W[6]=K*F+H*w+Y*I,W[1]=X*M+U*q+E*V,W[4]=X*z+U*_+E*A,W[7]=X*F+U*w+E*I,W[2]=N*M+G*q+D*V,W[5]=N*z+G*_+D*A,W[8]=N*F+G*w+D*I,this}multiplyScalar(J){let Q=this.elements;return Q[0]*=J,Q[3]*=J,Q[6]*=J,Q[1]*=J,Q[4]*=J,Q[7]*=J,Q[2]*=J,Q[5]*=J,Q[8]*=J,this}determinant(){let J=this.elements,Q=J[0],$=J[1],Z=J[2],W=J[3],K=J[4],H=J[5],Y=J[6],X=J[7],U=J[8];return Q*K*U-Q*H*X-$*W*U+$*H*Y+Z*W*X-Z*K*Y}invert(){let J=this.elements,Q=J[0],$=J[1],Z=J[2],W=J[3],K=J[4],H=J[5],Y=J[6],X=J[7],U=J[8],E=U*K-H*X,N=H*Y-U*W,G=X*W-K*Y,D=Q*E+$*N+Z*G;if(D===0)return this.set(0,0,0,0,0,0,0,0,0);let M=1/D;return J[0]=E*M,J[1]=(Z*X-U*$)*M,J[2]=(H*$-Z*K)*M,J[3]=N*M,J[4]=(U*Q-Z*Y)*M,J[5]=(Z*W-H*Q)*M,J[6]=G*M,J[7]=($*Y-X*Q)*M,J[8]=(K*Q-$*W)*M,this}transpose(){let J,Q=this.elements;return J=Q[1],Q[1]=Q[3],Q[3]=J,J=Q[2],Q[2]=Q[6],Q[6]=J,J=Q[5],Q[5]=Q[7],Q[7]=J,this}getNormalMatrix(J){return this.setFromMatrix4(J).invert().transpose()}transposeIntoArray(J){let Q=this.elements;return J[0]=Q[0],J[1]=Q[3],J[2]=Q[6],J[3]=Q[1],J[4]=Q[4],J[5]=Q[7],J[6]=Q[2],J[7]=Q[5],J[8]=Q[8],this}setUvTransform(J,Q,$,Z,W,K,H){let Y=Math.cos(W),X=Math.sin(W);return this.set($*Y,$*X,-$*(Y*K+X*H)+K+J,-Z*X,Z*Y,-Z*(-X*K+Y*H)+H+Q,0,0,1),this}scale(J,Q){return v9("Matrix3: .scale() is deprecated. Use .makeScale() instead."),this.premultiply(i6.makeScale(J,Q)),this}rotate(J){return v9("Matrix3: .rotate() is deprecated. Use .makeRotation() instead."),this.premultiply(i6.makeRotation(-J)),this}translate(J,Q){return v9("Matrix3: .translate() is deprecated. Use .makeTranslation() instead."),this.premultiply(i6.makeTranslation(J,Q)),this}makeTranslation(J,Q){if(J.isVector2)this.set(1,0,J.x,0,1,J.y,0,0,1);else this.set(1,0,J,0,1,Q,0,0,1);return this}makeRotation(J){let Q=Math.cos(J),$=Math.sin(J);return this.set(Q,-$,0,$,Q,0,0,0,1),this}makeScale(J,Q){return this.set(J,0,0,0,Q,0,0,0,1),this}equals(J){let Q=this.elements,$=J.elements;for(let Z=0;Z<9;Z++)if(Q[Z]!==$[Z])return!1;return!0}fromArray(J,Q=0){for(let $=0;$<9;$++)this.elements[$]=J[$+Q];return this}toArray(J=[],Q=0){let $=this.elements;return J[Q]=$[0],J[Q+1]=$[1],J[Q+2]=$[2],J[Q+3]=$[3],J[Q+4]=$[4],J[Q+5]=$[5],J[Q+6]=$[6],J[Q+7]=$[7],J[Q+8]=$[8],J}clone(){return new this.constructor().fromArray(this.elements)}}var i6=new P0,D$=new P0().set(0.4123908,0.3575843,0.1804808,0.212639,0.7151687,0.0721923,0.0193308,0.1191948,0.9505322),R$=new P0().set(3.2409699,-1.5373832,-0.4986108,-0.9692436,1.8759675,0.0415551,0.0556301,-0.203977,1.0569715);function pW(){let J={enabled:!0,workingColorSpace:"srgb-linear",spaces:{},convert:function(W,K,H){if(this.enabled===!1||K===H||!K||!H)return W;if(this.spaces[K].transfer==="srgb")W.r=U9(W.r),W.g=U9(W.g),W.b=U9(W.b);if(this.spaces[K].primaries!==this.spaces[H].primaries)W.applyMatrix3(this.spaces[K].toXYZ),W.applyMatrix3(this.spaces[H].fromXYZ);if(this.spaces[H].transfer==="srgb")W.r=U8(W.r),W.g=U8(W.g),W.b=U8(W.b);return W},workingToColorSpace:function(W,K){return this.convert(W,this.workingColorSpace,K)},colorSpaceToWorking:function(W,K){return this.convert(W,K,this.workingColorSpace)},getPrimaries:function(W){return this.spaces[W].primaries},getTransfer:function(W){if(W==="")return"linear";return this.spaces[W].transfer},getToneMappingMode:function(W){return this.spaces[W].outputColorSpaceConfig.toneMappingMode||"standard"},getLuminanceCoefficients:function(W,K=this.workingColorSpace){return W.fromArray(this.spaces[K].luminanceCoefficients)},define:function(W){Object.assign(this.spaces,W)},_getMatrix:function(W,K,H){return W.copy(this.spaces[K].toXYZ).multiply(this.spaces[H].fromXYZ)},_getDrawingBufferColorSpace:function(W){return this.spaces[W].outputColorSpaceConfig.drawingBufferColorSpace},_getUnpackColorSpace:function(W=this.workingColorSpace){return this.spaces[W].workingColorSpaceConfig.unpackColorSpace},fromWorkingColorSpace:function(W,K){return v9("ColorManagement: .fromWorkingColorSpace() has been renamed to .workingToColorSpace()."),J.workingToColorSpace(W,K)},toWorkingColorSpace:function(W,K){return v9("ColorManagement: .toWorkingColorSpace() has been renamed to .colorSpaceToWorking()."),J.colorSpaceToWorking(W,K)}},Q=[0.64,0.33,0.3,0.6,0.15,0.06],$=[0.2126,0.7152,0.0722],Z=[0.3127,0.329];return J.define({["srgb-linear"]:{primaries:Q,whitePoint:Z,transfer:"linear",toXYZ:D$,fromXYZ:R$,luminanceCoefficients:$,workingColorSpaceConfig:{unpackColorSpace:"srgb"},outputColorSpaceConfig:{drawingBufferColorSpace:"srgb"}},["srgb"]:{primaries:Q,whitePoint:Z,transfer:"srgb",toXYZ:D$,fromXYZ:R$,luminanceCoefficients:$,outputColorSpaceConfig:{drawingBufferColorSpace:"srgb"}}}),J}var h0=pW();function U9(J){return J<0.04045?J*0.0773993808:Math.pow(J*0.9478672986+0.0521327014,2.4)}function U8(J){return J<0.0031308?J*12.92:1.055*Math.pow(J,0.41666)-0.055}var r9;class DQ{static getDataURL(J,Q="image/png"){if(/^data:/i.test(J.src))return J.src;if(typeof HTMLCanvasElement>"u")return J.src;let $;if(J instanceof HTMLCanvasElement)$=J;else{if(r9===void 0)r9=A8("canvas");r9.width=J.width,r9.height=J.height;let Z=r9.getContext("2d");if(J instanceof ImageData)Z.putImageData(J,0,0);else Z.drawImage(J,0,0,J.width,J.height);$=r9}return $.toDataURL(Q)}static sRGBToLinear(J){if(typeof HTMLImageElement<"u"&&J instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&J instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&J instanceof ImageBitmap){let Q=A8("canvas");Q.width=J.width,Q.height=J.height;let $=Q.getContext("2d");$.drawImage(J,0,0,J.width,J.height);let Z=$.getImageData(0,0,J.width,J.height),W=Z.data;for(let K=0;K<W.length;K++)W[K]=U9(W[K]/255)*255;return $.putImageData(Z,0,0),Q}else if(J.data){let Q=J.data.slice(0);for(let $=0;$<Q.length;$++)if(Q instanceof Uint8Array||Q instanceof Uint8ClampedArray)Q[$]=Math.floor(U9(Q[$]/255)*255);else Q[$]=U9(Q[$]);return{data:Q,width:J.width,height:J.height}}else return C0("ImageUtils.sRGBToLinear(): Unsupported image type. No color space conversion applied."),J}}var mW=0;class j8{constructor(J=null){this.isSource=!0,Object.defineProperty(this,"id",{value:mW++}),this.uuid=S8(),this.data=J,this.dataReady=!0,this.version=0}getSize(J){let Q=this.data;if(typeof HTMLVideoElement<"u"&&Q instanceof HTMLVideoElement)J.set(Q.videoWidth,Q.videoHeight,0);else if(typeof VideoFrame<"u"&&Q instanceof VideoFrame)J.set(Q.displayWidth,Q.displayHeight,0);else if(Q!==null)J.set(Q.width,Q.height,Q.depth||0);else J.set(0,0,0);return J}set needsUpdate(J){if(J===!0)this.version++}toJSON(J){let Q=J===void 0||typeof J==="string";if(!Q&&J.images[this.uuid]!==void 0)return J.images[this.uuid];let $={uuid:this.uuid,url:""},Z=this.data;if(Z!==null){let W;if(Array.isArray(Z)){W=[];for(let K=0,H=Z.length;K<H;K++)if(Z[K].isDataTexture)W.push(o6(Z[K].image));else W.push(o6(Z[K]))}else W=o6(Z);$.url=W}if(!Q)J.images[this.uuid]=$;return $}}function o6(J){if(typeof HTMLImageElement<"u"&&J instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&J instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&J instanceof ImageBitmap)return DQ.getDataURL(J);else if(J.data)return{data:Array.from(J.data),width:J.width,height:J.height,type:J.data.constructor.name};else return C0("Texture: Unable to serialize Texture."),{}}var dW=0,a6=new b;class VJ extends N9{constructor(J=VJ.DEFAULT_IMAGE,Q=VJ.DEFAULT_MAPPING,$=1001,Z=1001,W=1006,K=1008,H=1023,Y=1009,X=VJ.DEFAULT_ANISOTROPY,U=""){super();this.isTexture=!0,Object.defineProperty(this,"id",{value:dW++}),this.uuid=S8(),this.name="",this.source=new j8(J),this.mipmaps=[],this.mapping=Q,this.channel=0,this.wrapS=$,this.wrapT=Z,this.magFilter=W,this.minFilter=K,this.anisotropy=X,this.format=H,this.internalFormat=null,this.type=Y,this.offset=new u0(0,0),this.repeat=new u0(1,1),this.center=new u0(0,0),this.rotation=0,this.matrixAutoUpdate=!0,this.matrix=new P0,this.generateMipmaps=!0,this.premultiplyAlpha=!1,this.flipY=!0,this.unpackAlignment=4,this.colorSpace=U,this.userData={},this.updateRanges=[],this.version=0,this.onUpdate=null,this.renderTarget=null,this.isRenderTargetTexture=!1,this.isArrayTexture=J&&J.depth&&J.depth>1?!0:!1,this.pmremVersion=0,this.normalized=!1}get width(){return this.source.getSize(a6).x}get height(){return this.source.getSize(a6).y}get depth(){return this.source.getSize(a6).z}get image(){return this.source.data}set image(J){this.source.data=J}updateMatrix(){this.matrix.setUvTransform(this.offset.x,this.offset.y,this.repeat.x,this.repeat.y,this.rotation,this.center.x,this.center.y)}addUpdateRange(J,Q){this.updateRanges.push({start:J,count:Q})}clearUpdateRanges(){this.updateRanges.length=0}clone(){return new this.constructor().copy(this)}copy(J){return this.name=J.name,this.source=J.source,this.mipmaps=J.mipmaps.slice(0),this.mapping=J.mapping,this.channel=J.channel,this.wrapS=J.wrapS,this.wrapT=J.wrapT,this.magFilter=J.magFilter,this.minFilter=J.minFilter,this.anisotropy=J.anisotropy,this.format=J.format,this.internalFormat=J.internalFormat,this.type=J.type,this.normalized=J.normalized,this.offset.copy(J.offset),this.repeat.copy(J.repeat),this.center.copy(J.center),this.rotation=J.rotation,this.matrixAutoUpdate=J.matrixAutoUpdate,this.matrix.copy(J.matrix),this.generateMipmaps=J.generateMipmaps,this.premultiplyAlpha=J.premultiplyAlpha,this.flipY=J.flipY,this.unpackAlignment=J.unpackAlignment,this.colorSpace=J.colorSpace,this.renderTarget=J.renderTarget,this.isRenderTargetTexture=J.isRenderTargetTexture,this.isArrayTexture=J.isArrayTexture,this.userData=JSON.parse(JSON.stringify(J.userData)),this.needsUpdate=!0,this}setValues(J){for(let Q in J){let $=J[Q];if($===void 0){C0(`Texture.setValues(): parameter '${Q}' has value of undefined.`);continue}let Z=this[Q];if(Z===void 0){C0(`Texture.setValues(): property '${Q}' does not exist.`);continue}if(Z&&$&&(Z.isVector2&&$.isVector2))Z.copy($);else if(Z&&$&&(Z.isVector3&&$.isVector3))Z.copy($);else if(Z&&$&&(Z.isMatrix3&&$.isMatrix3))Z.copy($);else this[Q]=$}}toJSON(J){let Q=J===void 0||typeof J==="string";if(!Q&&J.textures[this.uuid]!==void 0)return J.textures[this.uuid];let $={metadata:{version:4.7,type:"Texture",generator:"Texture.toJSON"},uuid:this.uuid,name:this.name,image:this.source.toJSON(J).uuid,mapping:this.mapping,channel:this.channel,repeat:[this.repeat.x,this.repeat.y],offset:[this.offset.x,this.offset.y],center:[this.center.x,this.center.y],rotation:this.rotation,wrap:[this.wrapS,this.wrapT],format:this.format,internalFormat:this.internalFormat,type:this.type,normalized:this.normalized,colorSpace:this.colorSpace,minFilter:this.minFilter,magFilter:this.magFilter,anisotropy:this.anisotropy,flipY:this.flipY,generateMipmaps:this.generateMipmaps,premultiplyAlpha:this.premultiplyAlpha,unpackAlignment:this.unpackAlignment};if(Object.keys(this.userData).length>0)$.userData=this.userData;if(!Q)J.textures[this.uuid]=$;return $}dispose(){this.dispatchEvent({type:"dispose"})}transformUv(J){if(this.mapping!==300)return J;if(J.applyMatrix3(this.matrix),J.x<0||J.x>1)switch(this.wrapS){case 1000:J.x=J.x-Math.floor(J.x);break;case 1001:J.x=J.x<0?0:1;break;case 1002:if(Math.abs(Math.floor(J.x)%2)===1)J.x=Math.ceil(J.x)-J.x;else J.x=J.x-Math.floor(J.x);break}if(J.y<0||J.y>1)switch(this.wrapT){case 1000:J.y=J.y-Math.floor(J.y);break;case 1001:J.y=J.y<0?0:1;break;case 1002:if(Math.abs(Math.floor(J.y)%2)===1)J.y=Math.ceil(J.y)-J.y;else J.y=J.y-Math.floor(J.y);break}if(this.flipY)J.y=1-J.y;return J}set needsUpdate(J){if(J===!0)this.version++,this.source.needsUpdate=!0}set needsPMREMUpdate(J){if(J===!0)this.pmremVersion++}}VJ.DEFAULT_IMAGE=null;VJ.DEFAULT_MAPPING=300;VJ.DEFAULT_ANISOTROPY=1;class KJ{static{KJ.prototype.isVector4=!0}constructor(J=0,Q=0,$=0,Z=1){this.x=J,this.y=Q,this.z=$,this.w=Z}get width(){return this.z}set width(J){this.z=J}get height(){return this.w}set height(J){this.w=J}set(J,Q,$,Z){return this.x=J,this.y=Q,this.z=$,this.w=Z,this}setScalar(J){return this.x=J,this.y=J,this.z=J,this.w=J,this}setX(J){return this.x=J,this}setY(J){return this.y=J,this}setZ(J){return this.z=J,this}setW(J){return this.w=J,this}setComponent(J,Q){switch(J){case 0:this.x=Q;break;case 1:this.y=Q;break;case 2:this.z=Q;break;case 3:this.w=Q;break;default:throw Error("THREE.Vector4: index is out of range: "+J)}return this}getComponent(J){switch(J){case 0:return this.x;case 1:return this.y;case 2:return this.z;case 3:return this.w;default:throw Error("THREE.Vector4: index is out of range: "+J)}}clone(){return new this.constructor(this.x,this.y,this.z,this.w)}copy(J){return this.x=J.x,this.y=J.y,this.z=J.z,this.w=J.w!==void 0?J.w:1,this}add(J){return this.x+=J.x,this.y+=J.y,this.z+=J.z,this.w+=J.w,this}addScalar(J){return this.x+=J,this.y+=J,this.z+=J,this.w+=J,this}addVectors(J,Q){return this.x=J.x+Q.x,this.y=J.y+Q.y,this.z=J.z+Q.z,this.w=J.w+Q.w,this}addScaledVector(J,Q){return this.x+=J.x*Q,this.y+=J.y*Q,this.z+=J.z*Q,this.w+=J.w*Q,this}sub(J){return this.x-=J.x,this.y-=J.y,this.z-=J.z,this.w-=J.w,this}subScalar(J){return this.x-=J,this.y-=J,this.z-=J,this.w-=J,this}subVectors(J,Q){return this.x=J.x-Q.x,this.y=J.y-Q.y,this.z=J.z-Q.z,this.w=J.w-Q.w,this}multiply(J){return this.x*=J.x,this.y*=J.y,this.z*=J.z,this.w*=J.w,this}multiplyScalar(J){return this.x*=J,this.y*=J,this.z*=J,this.w*=J,this}applyMatrix4(J){let Q=this.x,$=this.y,Z=this.z,W=this.w,K=J.elements;return this.x=K[0]*Q+K[4]*$+K[8]*Z+K[12]*W,this.y=K[1]*Q+K[5]*$+K[9]*Z+K[13]*W,this.z=K[2]*Q+K[6]*$+K[10]*Z+K[14]*W,this.w=K[3]*Q+K[7]*$+K[11]*Z+K[15]*W,this}divide(J){return this.x/=J.x,this.y/=J.y,this.z/=J.z,this.w/=J.w,this}divideScalar(J){return this.multiplyScalar(1/J)}setAxisAngleFromQuaternion(J){this.w=2*Math.acos(J.w);let Q=Math.sqrt(1-J.w*J.w);if(Q<0.0001)this.x=1,this.y=0,this.z=0;else this.x=J.x/Q,this.y=J.y/Q,this.z=J.z/Q;return this}setAxisAngleFromRotationMatrix(J){let Q,$,Z,W,K=0.01,H=0.1,Y=J.elements,X=Y[0],U=Y[4],E=Y[8],N=Y[1],G=Y[5],D=Y[9],M=Y[2],z=Y[6],F=Y[10];if(Math.abs(U-N)<0.01&&Math.abs(E-M)<0.01&&Math.abs(D-z)<0.01){if(Math.abs(U+N)<0.1&&Math.abs(E+M)<0.1&&Math.abs(D+z)<0.1&&Math.abs(X+G+F-3)<0.1)return this.set(1,0,0,0),this;Q=Math.PI;let _=(X+1)/2,w=(G+1)/2,V=(F+1)/2,A=(U+N)/4,I=(E+M)/4,P=(D+z)/4;if(_>w&&_>V)if(_<0.01)$=0,Z=0.707106781,W=0.707106781;else $=Math.sqrt(_),Z=A/$,W=I/$;else if(w>V)if(w<0.01)$=0.707106781,Z=0,W=0.707106781;else Z=Math.sqrt(w),$=A/Z,W=P/Z;else if(V<0.01)$=0.707106781,Z=0.707106781,W=0;else W=Math.sqrt(V),$=I/W,Z=P/W;return this.set($,Z,W,Q),this}let q=Math.sqrt((z-D)*(z-D)+(E-M)*(E-M)+(N-U)*(N-U));if(Math.abs(q)<0.001)q=1;return this.x=(z-D)/q,this.y=(E-M)/q,this.z=(N-U)/q,this.w=Math.acos((X+G+F-1)/2),this}setFromMatrixPosition(J){let Q=J.elements;return this.x=Q[12],this.y=Q[13],this.z=Q[14],this.w=Q[15],this}min(J){return this.x=Math.min(this.x,J.x),this.y=Math.min(this.y,J.y),this.z=Math.min(this.z,J.z),this.w=Math.min(this.w,J.w),this}max(J){return this.x=Math.max(this.x,J.x),this.y=Math.max(this.y,J.y),this.z=Math.max(this.z,J.z),this.w=Math.max(this.w,J.w),this}clamp(J,Q){return this.x=x0(this.x,J.x,Q.x),this.y=x0(this.y,J.y,Q.y),this.z=x0(this.z,J.z,Q.z),this.w=x0(this.w,J.w,Q.w),this}clampScalar(J,Q){return this.x=x0(this.x,J,Q),this.y=x0(this.y,J,Q),this.z=x0(this.z,J,Q),this.w=x0(this.w,J,Q),this}clampLength(J,Q){let $=this.length();return this.divideScalar($||1).multiplyScalar(x0($,J,Q))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this.w=Math.floor(this.w),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this.w=Math.ceil(this.w),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this.w=Math.round(this.w),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this.w=Math.trunc(this.w),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this.w=-this.w,this}dot(J){return this.x*J.x+this.y*J.y+this.z*J.z+this.w*J.w}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)+Math.abs(this.w)}normalize(){return this.divideScalar(this.length()||1)}setLength(J){return this.normalize().multiplyScalar(J)}lerp(J,Q){return this.x+=(J.x-this.x)*Q,this.y+=(J.y-this.y)*Q,this.z+=(J.z-this.z)*Q,this.w+=(J.w-this.w)*Q,this}lerpVectors(J,Q,$){return this.x=J.x+(Q.x-J.x)*$,this.y=J.y+(Q.y-J.y)*$,this.z=J.z+(Q.z-J.z)*$,this.w=J.w+(Q.w-J.w)*$,this}equals(J){return J.x===this.x&&J.y===this.y&&J.z===this.z&&J.w===this.w}fromArray(J,Q=0){return this.x=J[Q],this.y=J[Q+1],this.z=J[Q+2],this.w=J[Q+3],this}toArray(J=[],Q=0){return J[Q]=this.x,J[Q+1]=this.y,J[Q+2]=this.z,J[Q+3]=this.w,J}fromBufferAttribute(J,Q){return this.x=J.getX(Q),this.y=J.getY(Q),this.z=J.getZ(Q),this.w=J.getW(Q),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this.w=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z,yield this.w}}class RQ extends N9{constructor(J=1,Q=1,$={}){super();$=Object.assign({generateMipmaps:!1,internalFormat:null,minFilter:1006,depthBuffer:!0,stencilBuffer:!1,resolveDepthBuffer:!0,resolveStencilBuffer:!0,depthTexture:null,samples:0,count:1,depth:1,multiview:!1,useArrayDepthTexture:!1},$),this.isRenderTarget=!0,this.width=J,this.height=Q,this.depth=$.depth,this.scissor=new KJ(0,0,J,Q),this.scissorTest=!1,this.viewport=new KJ(0,0,J,Q),this.textures=[];let Z={width:J,height:Q,depth:$.depth},W=new VJ(Z),K=$.count;for(let H=0;H<K;H++)this.textures[H]=W.clone(),this.textures[H].isRenderTargetTexture=!0,this.textures[H].renderTarget=this;this._setTextureOptions($),this.depthBuffer=$.depthBuffer,this.stencilBuffer=$.stencilBuffer,this.resolveDepthBuffer=$.resolveDepthBuffer,this.resolveStencilBuffer=$.resolveStencilBuffer,this._depthTexture=null,this.depthTexture=$.depthTexture,this.samples=$.samples,this.multiview=$.multiview,this.useArrayDepthTexture=$.useArrayDepthTexture}_setTextureOptions(J={}){let Q={minFilter:1006,generateMipmaps:!1,flipY:!1,internalFormat:null};if(J.mapping!==void 0)Q.mapping=J.mapping;if(J.wrapS!==void 0)Q.wrapS=J.wrapS;if(J.wrapT!==void 0)Q.wrapT=J.wrapT;if(J.wrapR!==void 0)Q.wrapR=J.wrapR;if(J.magFilter!==void 0)Q.magFilter=J.magFilter;if(J.minFilter!==void 0)Q.minFilter=J.minFilter;if(J.format!==void 0)Q.format=J.format;if(J.type!==void 0)Q.type=J.type;if(J.anisotropy!==void 0)Q.anisotropy=J.anisotropy;if(J.colorSpace!==void 0)Q.colorSpace=J.colorSpace;if(J.flipY!==void 0)Q.flipY=J.flipY;if(J.generateMipmaps!==void 0)Q.generateMipmaps=J.generateMipmaps;if(J.internalFormat!==void 0)Q.internalFormat=J.internalFormat;for(let $=0;$<this.textures.length;$++)this.textures[$].setValues(Q)}get texture(){return this.textures[0]}set texture(J){this.textures[0]=J}set depthTexture(J){if(this._depthTexture!==null)this._depthTexture.renderTarget=null;if(J!==null)J.renderTarget=this;this._depthTexture=J}get depthTexture(){return this._depthTexture}setSize(J,Q,$=1){if(this.width!==J||this.height!==Q||this.depth!==$){this.width=J,this.height=Q,this.depth=$;for(let Z=0,W=this.textures.length;Z<W;Z++)if(this.textures[Z].image.width=J,this.textures[Z].image.height=Q,this.textures[Z].image.depth=$,this.textures[Z].isData3DTexture!==!0)this.textures[Z].isArrayTexture=this.textures[Z].image.depth>1;this.dispose()}this.viewport.set(0,0,J,Q),this.scissor.set(0,0,J,Q)}clone(){return new this.constructor().copy(this)}copy(J){this.width=J.width,this.height=J.height,this.depth=J.depth,this.scissor.copy(J.scissor),this.scissorTest=J.scissorTest,this.viewport.copy(J.viewport),this.textures.length=0;for(let Q=0,$=J.textures.length;Q<$;Q++){this.textures[Q]=J.textures[Q].clone(),this.textures[Q].isRenderTargetTexture=!0,this.textures[Q].renderTarget=this;let Z=Object.assign({},J.textures[Q].image);this.textures[Q].source=new j8(Z)}if(this.depthBuffer=J.depthBuffer,this.stencilBuffer=J.stencilBuffer,this.resolveDepthBuffer=J.resolveDepthBuffer,this.resolveStencilBuffer=J.resolveStencilBuffer,J.depthTexture!==null)this.depthTexture=J.depthTexture.clone();return this.samples=J.samples,this.multiview=J.multiview,this.useArrayDepthTexture=J.useArrayDepthTexture,this}dispose(){this.dispatchEvent({type:"dispose"})}}class xJ extends RQ{constructor(J=1,Q=1,$={}){super(J,Q,$);this.isWebGLRenderTarget=!0}}class z6 extends VJ{constructor(J=null,Q=1,$=1,Z=1){super(null);this.isDataArrayTexture=!0,this.image={data:J,width:Q,height:$,depth:Z},this.magFilter=1003,this.minFilter=1003,this.wrapR=1001,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1,this.layerUpdates=new Set}addLayerUpdate(J){this.layerUpdates.add(J)}clearLayerUpdates(){this.layerUpdates.clear()}}class OQ extends VJ{constructor(J=null,Q=1,$=1,Z=1){super(null);this.isData3DTexture=!0,this.image={data:J,width:Q,height:$,depth:Z},this.magFilter=1003,this.minFilter=1003,this.wrapR=1001,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}}class WJ{static{WJ.prototype.isMatrix4=!0}constructor(J,Q,$,Z,W,K,H,Y,X,U,E,N,G,D,M,z){if(this.elements=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],J!==void 0)this.set(J,Q,$,Z,W,K,H,Y,X,U,E,N,G,D,M,z)}set(J,Q,$,Z,W,K,H,Y,X,U,E,N,G,D,M,z){let F=this.elements;return F[0]=J,F[4]=Q,F[8]=$,F[12]=Z,F[1]=W,F[5]=K,F[9]=H,F[13]=Y,F[2]=X,F[6]=U,F[10]=E,F[14]=N,F[3]=G,F[7]=D,F[11]=M,F[15]=z,this}identity(){return this.set(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1),this}clone(){return new WJ().fromArray(this.elements)}copy(J){let Q=this.elements,$=J.elements;return Q[0]=$[0],Q[1]=$[1],Q[2]=$[2],Q[3]=$[3],Q[4]=$[4],Q[5]=$[5],Q[6]=$[6],Q[7]=$[7],Q[8]=$[8],Q[9]=$[9],Q[10]=$[10],Q[11]=$[11],Q[12]=$[12],Q[13]=$[13],Q[14]=$[14],Q[15]=$[15],this}copyPosition(J){let Q=this.elements,$=J.elements;return Q[12]=$[12],Q[13]=$[13],Q[14]=$[14],this}setFromMatrix3(J){let Q=J.elements;return this.set(Q[0],Q[3],Q[6],0,Q[1],Q[4],Q[7],0,Q[2],Q[5],Q[8],0,0,0,0,1),this}extractBasis(J,Q,$){if(this.determinantAffine()===0)return J.set(1,0,0),Q.set(0,1,0),$.set(0,0,1),this;return J.setFromMatrixColumn(this,0),Q.setFromMatrixColumn(this,1),$.setFromMatrixColumn(this,2),this}makeBasis(J,Q,$){return this.set(J.x,Q.x,$.x,0,J.y,Q.y,$.y,0,J.z,Q.z,$.z,0,0,0,0,1),this}extractRotation(J){if(J.determinantAffine()===0)return this.identity();let Q=this.elements,$=J.elements,Z=1/t9.setFromMatrixColumn(J,0).length(),W=1/t9.setFromMatrixColumn(J,1).length(),K=1/t9.setFromMatrixColumn(J,2).length();return Q[0]=$[0]*Z,Q[1]=$[1]*Z,Q[2]=$[2]*Z,Q[3]=0,Q[4]=$[4]*W,Q[5]=$[5]*W,Q[6]=$[6]*W,Q[7]=0,Q[8]=$[8]*K,Q[9]=$[9]*K,Q[10]=$[10]*K,Q[11]=0,Q[12]=0,Q[13]=0,Q[14]=0,Q[15]=1,this}makeRotationFromEuler(J){let Q=this.elements,$=J.x,Z=J.y,W=J.z,K=Math.cos($),H=Math.sin($),Y=Math.cos(Z),X=Math.sin(Z),U=Math.cos(W),E=Math.sin(W);if(J.order==="XYZ"){let N=K*U,G=K*E,D=H*U,M=H*E;Q[0]=Y*U,Q[4]=-Y*E,Q[8]=X,Q[1]=G+D*X,Q[5]=N-M*X,Q[9]=-H*Y,Q[2]=M-N*X,Q[6]=D+G*X,Q[10]=K*Y}else if(J.order==="YXZ"){let N=Y*U,G=Y*E,D=X*U,M=X*E;Q[0]=N+M*H,Q[4]=D*H-G,Q[8]=K*X,Q[1]=K*E,Q[5]=K*U,Q[9]=-H,Q[2]=G*H-D,Q[6]=M+N*H,Q[10]=K*Y}else if(J.order==="ZXY"){let N=Y*U,G=Y*E,D=X*U,M=X*E;Q[0]=N-M*H,Q[4]=-K*E,Q[8]=D+G*H,Q[1]=G+D*H,Q[5]=K*U,Q[9]=M-N*H,Q[2]=-K*X,Q[6]=H,Q[10]=K*Y}else if(J.order==="ZYX"){let N=K*U,G=K*E,D=H*U,M=H*E;Q[0]=Y*U,Q[4]=D*X-G,Q[8]=N*X+M,Q[1]=Y*E,Q[5]=M*X+N,Q[9]=G*X-D,Q[2]=-X,Q[6]=H*Y,Q[10]=K*Y}else if(J.order==="YZX"){let N=K*Y,G=K*X,D=H*Y,M=H*X;Q[0]=Y*U,Q[4]=M-N*E,Q[8]=D*E+G,Q[1]=E,Q[5]=K*U,Q[9]=-H*U,Q[2]=-X*U,Q[6]=G*E+D,Q[10]=N-M*E}else if(J.order==="XZY"){let N=K*Y,G=K*X,D=H*Y,M=H*X;Q[0]=Y*U,Q[4]=-E,Q[8]=X*U,Q[1]=N*E+M,Q[5]=K*U,Q[9]=G*E-D,Q[2]=D*E-G,Q[6]=H*U,Q[10]=M*E+N}return Q[3]=0,Q[7]=0,Q[11]=0,Q[12]=0,Q[13]=0,Q[14]=0,Q[15]=1,this}makeRotationFromQuaternion(J){return this.compose(lW,J,uW)}lookAt(J,Q,$){let Z=this.elements;if(TJ.subVectors(J,Q),TJ.lengthSq()===0)TJ.z=1;if(TJ.normalize(),k9.crossVectors($,TJ),k9.lengthSq()===0){if(Math.abs($.z)===1)TJ.x+=0.0001;else TJ.z+=0.0001;TJ.normalize(),k9.crossVectors($,TJ)}return k9.normalize(),d8.crossVectors(TJ,k9),Z[0]=k9.x,Z[4]=d8.x,Z[8]=TJ.x,Z[1]=k9.y,Z[5]=d8.y,Z[9]=TJ.y,Z[2]=k9.z,Z[6]=d8.z,Z[10]=TJ.z,this}multiply(J){return this.multiplyMatrices(this,J)}premultiply(J){return this.multiplyMatrices(J,this)}multiplyMatrices(J,Q){let $=J.elements,Z=Q.elements,W=this.elements,K=$[0],H=$[4],Y=$[8],X=$[12],U=$[1],E=$[5],N=$[9],G=$[13],D=$[2],M=$[6],z=$[10],F=$[14],q=$[3],_=$[7],w=$[11],V=$[15],A=Z[0],I=Z[4],P=Z[8],O=Z[12],B=Z[1],l=Z[5],C=Z[9],m=Z[13],o=Z[2],p=Z[6],n=Z[10],u=Z[14],h=Z[3],t=Z[7],e=Z[11],H0=Z[15];return W[0]=K*A+H*B+Y*o+X*h,W[4]=K*I+H*l+Y*p+X*t,W[8]=K*P+H*C+Y*n+X*e,W[12]=K*O+H*m+Y*u+X*H0,W[1]=U*A+E*B+N*o+G*h,W[5]=U*I+E*l+N*p+G*t,W[9]=U*P+E*C+N*n+G*e,W[13]=U*O+E*m+N*u+G*H0,W[2]=D*A+M*B+z*o+F*h,W[6]=D*I+M*l+z*p+F*t,W[10]=D*P+M*C+z*n+F*e,W[14]=D*O+M*m+z*u+F*H0,W[3]=q*A+_*B+w*o+V*h,W[7]=q*I+_*l+w*p+V*t,W[11]=q*P+_*C+w*n+V*e,W[15]=q*O+_*m+w*u+V*H0,this}multiplyScalar(J){let Q=this.elements;return Q[0]*=J,Q[4]*=J,Q[8]*=J,Q[12]*=J,Q[1]*=J,Q[5]*=J,Q[9]*=J,Q[13]*=J,Q[2]*=J,Q[6]*=J,Q[10]*=J,Q[14]*=J,Q[3]*=J,Q[7]*=J,Q[11]*=J,Q[15]*=J,this}determinant(){let J=this.elements,Q=J[0],$=J[4],Z=J[8],W=J[12],K=J[1],H=J[5],Y=J[9],X=J[13],U=J[2],E=J[6],N=J[10],G=J[14],D=J[3],M=J[7],z=J[11],F=J[15],q=Y*G-X*N,_=H*G-X*E,w=H*N-Y*E,V=K*G-X*U,A=K*N-Y*U,I=K*E-H*U;return Q*(M*q-z*_+F*w)-$*(D*q-z*V+F*A)+Z*(D*_-M*V+F*I)-W*(D*w-M*A+z*I)}determinantAffine(){let J=this.elements,Q=J[0],$=J[4],Z=J[8],W=J[1],K=J[5],H=J[9],Y=J[2],X=J[6],U=J[10];return Q*(K*U-H*X)-$*(W*U-H*Y)+Z*(W*X-K*Y)}transpose(){let J=this.elements,Q;return Q=J[1],J[1]=J[4],J[4]=Q,Q=J[2],J[2]=J[8],J[8]=Q,Q=J[6],J[6]=J[9],J[9]=Q,Q=J[3],J[3]=J[12],J[12]=Q,Q=J[7],J[7]=J[13],J[13]=Q,Q=J[11],J[11]=J[14],J[14]=Q,this}setPosition(J,Q,$){let Z=this.elements;if(J.isVector3)Z[12]=J.x,Z[13]=J.y,Z[14]=J.z;else Z[12]=J,Z[13]=Q,Z[14]=$;return this}invert(){let J=this.elements,Q=J[0],$=J[1],Z=J[2],W=J[3],K=J[4],H=J[5],Y=J[6],X=J[7],U=J[8],E=J[9],N=J[10],G=J[11],D=J[12],M=J[13],z=J[14],F=J[15],q=Q*H-$*K,_=Q*Y-Z*K,w=Q*X-W*K,V=$*Y-Z*H,A=$*X-W*H,I=Z*X-W*Y,P=U*M-E*D,O=U*z-N*D,B=U*F-G*D,l=E*z-N*M,C=E*F-G*M,m=N*F-G*z,o=q*m-_*C+w*l+V*B-A*O+I*P;if(o===0)return this.set(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);let p=1/o;return J[0]=(H*m-Y*C+X*l)*p,J[1]=(Z*C-$*m-W*l)*p,J[2]=(M*I-z*A+F*V)*p,J[3]=(N*A-E*I-G*V)*p,J[4]=(Y*B-K*m-X*O)*p,J[5]=(Q*m-Z*B+W*O)*p,J[6]=(z*w-D*I-F*_)*p,J[7]=(U*I-N*w+G*_)*p,J[8]=(K*C-H*B+X*P)*p,J[9]=($*B-Q*C-W*P)*p,J[10]=(D*A-M*w+F*q)*p,J[11]=(E*w-U*A-G*q)*p,J[12]=(H*O-K*l-Y*P)*p,J[13]=(Q*l-$*O+Z*P)*p,J[14]=(M*_-D*V-z*q)*p,J[15]=(U*V-E*_+N*q)*p,this}scale(J){let Q=this.elements,$=J.x,Z=J.y,W=J.z;return Q[0]*=$,Q[4]*=Z,Q[8]*=W,Q[1]*=$,Q[5]*=Z,Q[9]*=W,Q[2]*=$,Q[6]*=Z,Q[10]*=W,Q[3]*=$,Q[7]*=Z,Q[11]*=W,this}getMaxScaleOnAxis(){let J=this.elements,Q=J[0]*J[0]+J[1]*J[1]+J[2]*J[2],$=J[4]*J[4]+J[5]*J[5]+J[6]*J[6],Z=J[8]*J[8]+J[9]*J[9]+J[10]*J[10];return Math.sqrt(Math.max(Q,$,Z))}makeTranslation(J,Q,$){if(J.isVector3)this.set(1,0,0,J.x,0,1,0,J.y,0,0,1,J.z,0,0,0,1);else this.set(1,0,0,J,0,1,0,Q,0,0,1,$,0,0,0,1);return this}makeRotationX(J){let Q=Math.cos(J),$=Math.sin(J);return this.set(1,0,0,0,0,Q,-$,0,0,$,Q,0,0,0,0,1),this}makeRotationY(J){let Q=Math.cos(J),$=Math.sin(J);return this.set(Q,0,$,0,0,1,0,0,-$,0,Q,0,0,0,0,1),this}makeRotationZ(J){let Q=Math.cos(J),$=Math.sin(J);return this.set(Q,-$,0,0,$,Q,0,0,0,0,1,0,0,0,0,1),this}makeRotationAxis(J,Q){let $=Math.cos(Q),Z=Math.sin(Q),W=1-$,K=J.x,H=J.y,Y=J.z,X=W*K,U=W*H;return this.set(X*K+$,X*H-Z*Y,X*Y+Z*H,0,X*H+Z*Y,U*H+$,U*Y-Z*K,0,X*Y-Z*H,U*Y+Z*K,W*Y*Y+$,0,0,0,0,1),this}makeScale(J,Q,$){return this.set(J,0,0,0,0,Q,0,0,0,0,$,0,0,0,0,1),this}makeShear(J,Q,$,Z,W,K){return this.set(1,$,W,0,J,1,K,0,Q,Z,1,0,0,0,0,1),this}compose(J,Q,$){let Z=this.elements,W=Q._x,K=Q._y,H=Q._z,Y=Q._w,X=W+W,U=K+K,E=H+H,N=W*X,G=W*U,D=W*E,M=K*U,z=K*E,F=H*E,q=Y*X,_=Y*U,w=Y*E,V=$.x,A=$.y,I=$.z;return Z[0]=(1-(M+F))*V,Z[1]=(G+w)*V,Z[2]=(D-_)*V,Z[3]=0,Z[4]=(G-w)*A,Z[5]=(1-(N+F))*A,Z[6]=(z+q)*A,Z[7]=0,Z[8]=(D+_)*I,Z[9]=(z-q)*I,Z[10]=(1-(N+M))*I,Z[11]=0,Z[12]=J.x,Z[13]=J.y,Z[14]=J.z,Z[15]=1,this}decompose(J,Q,$){let Z=this.elements;J.x=Z[12],J.y=Z[13],J.z=Z[14];let W=this.determinantAffine();if(W===0)return $.set(1,1,1),Q.identity(),this;let K=t9.set(Z[0],Z[1],Z[2]).length(),H=t9.set(Z[4],Z[5],Z[6]).length(),Y=t9.set(Z[8],Z[9],Z[10]).length();if(W<0)K=-K;mJ.copy(this);let X=1/K,U=1/H,E=1/Y;return mJ.elements[0]*=X,mJ.elements[1]*=X,mJ.elements[2]*=X,mJ.elements[4]*=U,mJ.elements[5]*=U,mJ.elements[6]*=U,mJ.elements[8]*=E,mJ.elements[9]*=E,mJ.elements[10]*=E,Q.setFromRotationMatrix(mJ),$.x=K,$.y=H,$.z=Y,this}makePerspective(J,Q,$,Z,W,K,H=2000,Y=!1){let X=this.elements,U=2*W/(Q-J),E=2*W/($-Z),N=(Q+J)/(Q-J),G=($+Z)/($-Z),D,M;if(Y)D=W/(K-W),M=K*W/(K-W);else if(H===2000)D=-(K+W)/(K-W),M=-2*K*W/(K-W);else if(H===2001)D=-K/(K-W),M=-K*W/(K-W);else throw Error("THREE.Matrix4.makePerspective(): Invalid coordinate system: "+H);return X[0]=U,X[4]=0,X[8]=N,X[12]=0,X[1]=0,X[5]=E,X[9]=G,X[13]=0,X[2]=0,X[6]=0,X[10]=D,X[14]=M,X[3]=0,X[7]=0,X[11]=-1,X[15]=0,this}makeOrthographic(J,Q,$,Z,W,K,H=2000,Y=!1){let X=this.elements,U=2/(Q-J),E=2/($-Z),N=-(Q+J)/(Q-J),G=-($+Z)/($-Z),D,M;if(Y)D=1/(K-W),M=K/(K-W);else if(H===2000)D=-2/(K-W),M=-(K+W)/(K-W);else if(H===2001)D=-1/(K-W),M=-W/(K-W);else throw Error("THREE.Matrix4.makeOrthographic(): Invalid coordinate system: "+H);return X[0]=U,X[4]=0,X[8]=0,X[12]=N,X[1]=0,X[5]=E,X[9]=0,X[13]=G,X[2]=0,X[6]=0,X[10]=D,X[14]=M,X[3]=0,X[7]=0,X[11]=0,X[15]=1,this}equals(J){let Q=this.elements,$=J.elements;for(let Z=0;Z<16;Z++)if(Q[Z]!==$[Z])return!1;return!0}fromArray(J,Q=0){for(let $=0;$<16;$++)this.elements[$]=J[$+Q];return this}toArray(J=[],Q=0){let $=this.elements;return J[Q]=$[0],J[Q+1]=$[1],J[Q+2]=$[2],J[Q+3]=$[3],J[Q+4]=$[4],J[Q+5]=$[5],J[Q+6]=$[6],J[Q+7]=$[7],J[Q+8]=$[8],J[Q+9]=$[9],J[Q+10]=$[10],J[Q+11]=$[11],J[Q+12]=$[12],J[Q+13]=$[13],J[Q+14]=$[14],J[Q+15]=$[15],J}}var t9=new b,mJ=new WJ,lW=new b(0,0,0),uW=new b(1,1,1),k9=new b,d8=new b,TJ=new b,O$=new WJ,k$=new q9;class A9{constructor(J=0,Q=0,$=0,Z=A9.DEFAULT_ORDER){this.isEuler=!0,this._x=J,this._y=Q,this._z=$,this._order=Z}get x(){return this._x}set x(J){this._x=J,this._onChangeCallback()}get y(){return this._y}set y(J){this._y=J,this._onChangeCallback()}get z(){return this._z}set z(J){this._z=J,this._onChangeCallback()}get order(){return this._order}set order(J){this._order=J,this._onChangeCallback()}set(J,Q,$,Z=this._order){return this._x=J,this._y=Q,this._z=$,this._order=Z,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._order)}copy(J){return this._x=J._x,this._y=J._y,this._z=J._z,this._order=J._order,this._onChangeCallback(),this}setFromRotationMatrix(J,Q=this._order,$=!0){let Z=J.elements,W=Z[0],K=Z[4],H=Z[8],Y=Z[1],X=Z[5],U=Z[9],E=Z[2],N=Z[6],G=Z[10];switch(Q){case"XYZ":if(this._y=Math.asin(x0(H,-1,1)),Math.abs(H)<0.9999999)this._x=Math.atan2(-U,G),this._z=Math.atan2(-K,W);else this._x=Math.atan2(N,X),this._z=0;break;case"YXZ":if(this._x=Math.asin(-x0(U,-1,1)),Math.abs(U)<0.9999999)this._y=Math.atan2(H,G),this._z=Math.atan2(Y,X);else this._y=Math.atan2(-E,W),this._z=0;break;case"ZXY":if(this._x=Math.asin(x0(N,-1,1)),Math.abs(N)<0.9999999)this._y=Math.atan2(-E,G),this._z=Math.atan2(-K,X);else this._y=0,this._z=Math.atan2(Y,W);break;case"ZYX":if(this._y=Math.asin(-x0(E,-1,1)),Math.abs(E)<0.9999999)this._x=Math.atan2(N,G),this._z=Math.atan2(Y,W);else this._x=0,this._z=Math.atan2(-K,X);break;case"YZX":if(this._z=Math.asin(x0(Y,-1,1)),Math.abs(Y)<0.9999999)this._x=Math.atan2(-U,X),this._y=Math.atan2(-E,W);else this._x=0,this._y=Math.atan2(H,G);break;case"XZY":if(this._z=Math.asin(-x0(K,-1,1)),Math.abs(K)<0.9999999)this._x=Math.atan2(N,X),this._y=Math.atan2(H,W);else this._x=Math.atan2(-U,G),this._y=0;break;default:C0("Euler: .setFromRotationMatrix() encountered an unknown order: "+Q)}if(this._order=Q,$===!0)this._onChangeCallback();return this}setFromQuaternion(J,Q,$){return O$.makeRotationFromQuaternion(J),this.setFromRotationMatrix(O$,Q,$)}setFromVector3(J,Q=this._order){return this.set(J.x,J.y,J.z,Q)}reorder(J){return k$.setFromEuler(this),this.setFromQuaternion(k$,J)}equals(J){return J._x===this._x&&J._y===this._y&&J._z===this._z&&J._order===this._order}fromArray(J){if(this._x=J[0],this._y=J[1],this._z=J[2],J[3]!==void 0)this._order=J[3];return this._onChangeCallback(),this}toArray(J=[],Q=0){return J[Q]=this._x,J[Q+1]=this._y,J[Q+2]=this._z,J[Q+3]=this._order,J}_onChange(J){return this._onChangeCallback=J,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._order}}A9.DEFAULT_ORDER="XYZ";class I6{constructor(){this.mask=1}set(J){this.mask=(1<<J|0)>>>0}enable(J){this.mask|=1<<J|0}enableAll(){this.mask=-1}toggle(J){this.mask^=1<<J|0}disable(J){this.mask&=~(1<<J|0)}disableAll(){this.mask=0}test(J){return(this.mask&J.mask)!==0}isEnabled(J){return(this.mask&(1<<J|0))!==0}}var cW=0,M$=new b,e9=new q9,Z9=new WJ,l8=new b,V8=new b,nW=new b,sW=new q9,L$=new b(1,0,0),V$=new b(0,1,0),B$=new b(0,0,1),z$={type:"added"},iW={type:"removed"},J8={type:"childadded",child:null},r6={type:"childremoved",child:null};class BJ extends N9{constructor(){super();this.isObject3D=!0,Object.defineProperty(this,"id",{value:cW++}),this.uuid=S8(),this.name="",this.type="Object3D",this.parent=null,this.children=[],this.up=BJ.DEFAULT_UP.clone();let J=new b,Q=new A9,$=new q9,Z=new b(1,1,1);function W(){$.setFromEuler(Q,!1)}function K(){Q.setFromQuaternion($,void 0,!1)}Q._onChange(W),$._onChange(K),Object.defineProperties(this,{position:{configurable:!0,enumerable:!0,value:J},rotation:{configurable:!0,enumerable:!0,value:Q},quaternion:{configurable:!0,enumerable:!0,value:$},scale:{configurable:!0,enumerable:!0,value:Z},modelViewMatrix:{value:new WJ},normalMatrix:{value:new P0}}),this.matrix=new WJ,this.matrixWorld=new WJ,this.matrixAutoUpdate=BJ.DEFAULT_MATRIX_AUTO_UPDATE,this.matrixWorldAutoUpdate=BJ.DEFAULT_MATRIX_WORLD_AUTO_UPDATE,this.matrixWorldNeedsUpdate=!1,this.layers=new I6,this.visible=!0,this.castShadow=!1,this.receiveShadow=!1,this.frustumCulled=!0,this.renderOrder=0,this.animations=[],this.customDepthMaterial=void 0,this.customDistanceMaterial=void 0,this.static=!1,this.userData={},this.pivot=null}onBeforeShadow(){}onAfterShadow(){}onBeforeRender(){}onAfterRender(){}applyMatrix4(J){if(this.matrixAutoUpdate)this.updateMatrix();this.matrix.premultiply(J),this.matrix.decompose(this.position,this.quaternion,this.scale)}applyQuaternion(J){return this.quaternion.premultiply(J),this}setRotationFromAxisAngle(J,Q){this.quaternion.setFromAxisAngle(J,Q)}setRotationFromEuler(J){this.quaternion.setFromEuler(J,!0)}setRotationFromMatrix(J){this.quaternion.setFromRotationMatrix(J)}setRotationFromQuaternion(J){this.quaternion.copy(J)}rotateOnAxis(J,Q){return e9.setFromAxisAngle(J,Q),this.quaternion.multiply(e9),this}rotateOnWorldAxis(J,Q){return e9.setFromAxisAngle(J,Q),this.quaternion.premultiply(e9),this}rotateX(J){return this.rotateOnAxis(L$,J)}rotateY(J){return this.rotateOnAxis(V$,J)}rotateZ(J){return this.rotateOnAxis(B$,J)}translateOnAxis(J,Q){return M$.copy(J).applyQuaternion(this.quaternion),this.position.add(M$.multiplyScalar(Q)),this}translateX(J){return this.translateOnAxis(L$,J)}translateY(J){return this.translateOnAxis(V$,J)}translateZ(J){return this.translateOnAxis(B$,J)}localToWorld(J){return this.updateWorldMatrix(!0,!1),J.applyMatrix4(this.matrixWorld)}worldToLocal(J){return this.updateWorldMatrix(!0,!1),J.applyMatrix4(Z9.copy(this.matrixWorld).invert())}lookAt(J,Q,$){if(J.isVector3)l8.copy(J);else l8.set(J,Q,$);let Z=this.parent;if(this.updateWorldMatrix(!0,!1),V8.setFromMatrixPosition(this.matrixWorld),this.isCamera||this.isLight)Z9.lookAt(V8,l8,this.up);else Z9.lookAt(l8,V8,this.up);if(this.quaternion.setFromRotationMatrix(Z9),Z)Z9.extractRotation(Z.matrixWorld),e9.setFromRotationMatrix(Z9),this.quaternion.premultiply(e9.invert())}add(J){if(arguments.length>1){for(let Q=0;Q<arguments.length;Q++)this.add(arguments[Q]);return this}if(J===this)return _0("Object3D.add: object can't be added as a child of itself.",J),this;if(J&&J.isObject3D)J.removeFromParent(),J.parent=this,this.children.push(J),J.dispatchEvent(z$),J8.child=J,this.dispatchEvent(J8),J8.child=null;else _0("Object3D.add: object not an instance of THREE.Object3D.",J);return this}remove(J){if(arguments.length>1){for(let $=0;$<arguments.length;$++)this.remove(arguments[$]);return this}let Q=this.children.indexOf(J);if(Q!==-1)J.parent=null,this.children.splice(Q,1),J.dispatchEvent(iW),r6.child=J,this.dispatchEvent(r6),r6.child=null;return this}removeFromParent(){let J=this.parent;if(J!==null)J.remove(this);return this}clear(){return this.remove(...this.children)}attach(J){if(this.updateWorldMatrix(!0,!1),Z9.copy(this.matrixWorld).invert(),J.parent!==null)J.parent.updateWorldMatrix(!0,!1),Z9.multiply(J.parent.matrixWorld);return J.applyMatrix4(Z9),J.removeFromParent(),J.parent=this,this.children.push(J),J.updateWorldMatrix(!1,!0),J.dispatchEvent(z$),J8.child=J,this.dispatchEvent(J8),J8.child=null,this}getObjectById(J){return this.getObjectByProperty("id",J)}getObjectByName(J){return this.getObjectByProperty("name",J)}getObjectByProperty(J,Q){if(this[J]===Q)return this;for(let $=0,Z=this.children.length;$<Z;$++){let K=this.children[$].getObjectByProperty(J,Q);if(K!==void 0)return K}return}getObjectsByProperty(J,Q,$=[]){if(this[J]===Q)$.push(this);let Z=this.children;for(let W=0,K=Z.length;W<K;W++)Z[W].getObjectsByProperty(J,Q,$);return $}getWorldPosition(J){return this.updateWorldMatrix(!0,!1),J.setFromMatrixPosition(this.matrixWorld)}getWorldQuaternion(J){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(V8,J,nW),J}getWorldScale(J){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(V8,sW,J),J}getWorldDirection(J){this.updateWorldMatrix(!0,!1);let Q=this.matrixWorld.elements;return J.set(Q[8],Q[9],Q[10]).normalize()}raycast(){}traverse(J){J(this);let Q=this.children;for(let $=0,Z=Q.length;$<Z;$++)Q[$].traverse(J)}traverseVisible(J){if(this.visible===!1)return;J(this);let Q=this.children;for(let $=0,Z=Q.length;$<Z;$++)Q[$].traverseVisible(J)}traverseAncestors(J){let Q=this.parent;if(Q!==null)J(Q),Q.traverseAncestors(J)}updateMatrix(){this.matrix.compose(this.position,this.quaternion,this.scale);let J=this.pivot;if(J!==null){let{x:Q,y:$,z:Z}=J,W=this.matrix.elements;W[12]+=Q-W[0]*Q-W[4]*$-W[8]*Z,W[13]+=$-W[1]*Q-W[5]*$-W[9]*Z,W[14]+=Z-W[2]*Q-W[6]*$-W[10]*Z}this.matrixWorldNeedsUpdate=!0}updateMatrixWorld(J){if(this.matrixAutoUpdate)this.updateMatrix();if(this.matrixWorldNeedsUpdate||J){if(this.matrixWorldAutoUpdate===!0)if(this.parent===null)this.matrixWorld.copy(this.matrix);else this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix);this.matrixWorldNeedsUpdate=!1,J=!0}let Q=this.children;for(let $=0,Z=Q.length;$<Z;$++)Q[$].updateMatrixWorld(J)}updateWorldMatrix(J,Q,$=!1){let Z=this.parent;if(J===!0&&Z!==null)Z.updateWorldMatrix(!0,!1);if(this.matrixAutoUpdate)this.updateMatrix();if(this.matrixWorldNeedsUpdate||$){if(this.matrixWorldAutoUpdate===!0)if(this.parent===null)this.matrixWorld.copy(this.matrix);else this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix);this.matrixWorldNeedsUpdate=!1,$=!0}if(Q===!0){let W=this.children;for(let K=0,H=W.length;K<H;K++)W[K].updateWorldMatrix(!1,!0,$)}}toJSON(J){let Q=J===void 0||typeof J==="string",$={};if(Q)J={geometries:{},materials:{},textures:{},images:{},shapes:{},skeletons:{},animations:{},nodes:{}},$.metadata={version:4.7,type:"Object",generator:"Object3D.toJSON"};let Z={};if(Z.uuid=this.uuid,Z.type=this.type,this.name!=="")Z.name=this.name;if(this.castShadow===!0)Z.castShadow=!0;if(this.receiveShadow===!0)Z.receiveShadow=!0;if(this.visible===!1)Z.visible=!1;if(this.frustumCulled===!1)Z.frustumCulled=!1;if(this.renderOrder!==0)Z.renderOrder=this.renderOrder;if(this.static!==!1)Z.static=this.static;if(Object.keys(this.userData).length>0)Z.userData=this.userData;if(Z.layers=this.layers.mask,Z.matrix=this.matrix.toArray(),Z.up=this.up.toArray(),this.pivot!==null)Z.pivot=this.pivot.toArray();if(this.matrixAutoUpdate===!1)Z.matrixAutoUpdate=!1;if(this.morphTargetDictionary!==void 0)Z.morphTargetDictionary=Object.assign({},this.morphTargetDictionary);if(this.morphTargetInfluences!==void 0)Z.morphTargetInfluences=this.morphTargetInfluences.slice();if(this.isInstancedMesh){if(Z.type="InstancedMesh",Z.count=this.count,Z.instanceMatrix=this.instanceMatrix.toJSON(),this.instanceColor!==null)Z.instanceColor=this.instanceColor.toJSON()}if(this.isBatchedMesh){if(Z.type="BatchedMesh",Z.perObjectFrustumCulled=this.perObjectFrustumCulled,Z.sortObjects=this.sortObjects,Z.drawRanges=this._drawRanges,Z.reservedRanges=this._reservedRanges,Z.geometryInfo=this._geometryInfo.map((H)=>({...H,boundingBox:H.boundingBox?H.boundingBox.toJSON():void 0,boundingSphere:H.boundingSphere?H.boundingSphere.toJSON():void 0})),Z.instanceInfo=this._instanceInfo.map((H)=>({...H})),Z.availableInstanceIds=this._availableInstanceIds.slice(),Z.availableGeometryIds=this._availableGeometryIds.slice(),Z.nextIndexStart=this._nextIndexStart,Z.nextVertexStart=this._nextVertexStart,Z.geometryCount=this._geometryCount,Z.maxInstanceCount=this._maxInstanceCount,Z.maxVertexCount=this._maxVertexCount,Z.maxIndexCount=this._maxIndexCount,Z.geometryInitialized=this._geometryInitialized,Z.matricesTexture=this._matricesTexture.toJSON(J),Z.indirectTexture=this._indirectTexture.toJSON(J),this._colorsTexture!==null)Z.colorsTexture=this._colorsTexture.toJSON(J);if(this.boundingSphere!==null)Z.boundingSphere=this.boundingSphere.toJSON();if(this.boundingBox!==null)Z.boundingBox=this.boundingBox.toJSON()}function W(H,Y){if(H[Y.uuid]===void 0)H[Y.uuid]=Y.toJSON(J);return Y.uuid}if(this.isScene){if(this.background){if(this.background.isColor)Z.background=this.background.toJSON();else if(this.background.isTexture)Z.background=this.background.toJSON(J).uuid}if(this.environment&&this.environment.isTexture&&this.environment.isRenderTargetTexture!==!0)Z.environment=this.environment.toJSON(J).uuid}else if(this.isMesh||this.isLine||this.isPoints){Z.geometry=W(J.geometries,this.geometry);let H=this.geometry.parameters;if(H!==void 0&&H.shapes!==void 0){let Y=H.shapes;if(Array.isArray(Y))for(let X=0,U=Y.length;X<U;X++){let E=Y[X];W(J.shapes,E)}else W(J.shapes,Y)}}if(this.isSkinnedMesh){if(Z.bindMode=this.bindMode,Z.bindMatrix=this.bindMatrix.toArray(),this.skeleton!==void 0)W(J.skeletons,this.skeleton),Z.skeleton=this.skeleton.uuid}if(this.material!==void 0)if(Array.isArray(this.material)){let H=[];for(let Y=0,X=this.material.length;Y<X;Y++)H.push(W(J.materials,this.material[Y]));Z.material=H}else Z.material=W(J.materials,this.material);if(this.children.length>0){Z.children=[];for(let H=0;H<this.children.length;H++)Z.children.push(this.children[H].toJSON(J).object)}if(this.animations.length>0){Z.animations=[];for(let H=0;H<this.animations.length;H++){let Y=this.animations[H];Z.animations.push(W(J.animations,Y))}}if(Q){let H=K(J.geometries),Y=K(J.materials),X=K(J.textures),U=K(J.images),E=K(J.shapes),N=K(J.skeletons),G=K(J.animations),D=K(J.nodes);if(H.length>0)$.geometries=H;if(Y.length>0)$.materials=Y;if(X.length>0)$.textures=X;if(U.length>0)$.images=U;if(E.length>0)$.shapes=E;if(N.length>0)$.skeletons=N;if(G.length>0)$.animations=G;if(D.length>0)$.nodes=D}return $.object=Z,$;function K(H){let Y=[];for(let X in H){let U=H[X];delete U.metadata,Y.push(U)}return Y}}clone(J){return new this.constructor().copy(this,J)}copy(J,Q=!0){if(this.name=J.name,this.up.copy(J.up),this.position.copy(J.position),this.rotation.order=J.rotation.order,this.quaternion.copy(J.quaternion),this.scale.copy(J.scale),this.pivot=J.pivot!==null?J.pivot.clone():null,this.matrix.copy(J.matrix),this.matrixWorld.copy(J.matrixWorld),this.matrixAutoUpdate=J.matrixAutoUpdate,this.matrixWorldAutoUpdate=J.matrixWorldAutoUpdate,this.matrixWorldNeedsUpdate=J.matrixWorldNeedsUpdate,this.layers.mask=J.layers.mask,this.visible=J.visible,this.castShadow=J.castShadow,this.receiveShadow=J.receiveShadow,this.frustumCulled=J.frustumCulled,this.renderOrder=J.renderOrder,this.static=J.static,this.animations=J.animations.slice(),this.userData=JSON.parse(JSON.stringify(J.userData)),Q===!0)for(let $=0;$<J.children.length;$++){let Z=J.children[$];this.add(Z.clone())}return this}}BJ.DEFAULT_UP=new b(0,1,0);BJ.DEFAULT_MATRIX_AUTO_UPDATE=!0;BJ.DEFAULT_MATRIX_WORLD_AUTO_UPDATE=!0;class I9 extends BJ{constructor(){super();this.isGroup=!0,this.type="Group"}}var oW={type:"move"};class y8{constructor(){this._targetRay=null,this._grip=null,this._hand=null}getHandSpace(){if(this._hand===null)this._hand=new I9,this._hand.matrixAutoUpdate=!1,this._hand.visible=!1,this._hand.joints={},this._hand.inputState={pinching:!1};return this._hand}getTargetRaySpace(){if(this._targetRay===null)this._targetRay=new I9,this._targetRay.matrixAutoUpdate=!1,this._targetRay.visible=!1,this._targetRay.hasLinearVelocity=!1,this._targetRay.linearVelocity=new b,this._targetRay.hasAngularVelocity=!1,this._targetRay.angularVelocity=new b;return this._targetRay}getGripSpace(){if(this._grip===null)this._grip=new I9,this._grip.matrixAutoUpdate=!1,this._grip.visible=!1,this._grip.hasLinearVelocity=!1,this._grip.linearVelocity=new b,this._grip.hasAngularVelocity=!1,this._grip.angularVelocity=new b,this._grip.eventsEnabled=!1;return this._grip}dispatchEvent(J){if(this._targetRay!==null)this._targetRay.dispatchEvent(J);if(this._grip!==null)this._grip.dispatchEvent(J);if(this._hand!==null)this._hand.dispatchEvent(J);return this}connect(J){if(J&&J.hand){let Q=this._hand;if(Q)for(let $ of J.hand.values())this._getHandJoint(Q,$)}return this.dispatchEvent({type:"connected",data:J}),this}disconnect(J){if(this.dispatchEvent({type:"disconnected",data:J}),this._targetRay!==null)this._targetRay.visible=!1;if(this._grip!==null)this._grip.visible=!1;if(this._hand!==null)this._hand.visible=!1;return this}update(J,Q,$){let Z=null,W=null,K=null,H=this._targetRay,Y=this._grip,X=this._hand;if(J&&Q.session.visibilityState!=="visible-blurred"){if(X&&J.hand){K=!0;for(let M of J.hand.values()){let z=Q.getJointPose(M,$),F=this._getHandJoint(X,M);if(z!==null)F.matrix.fromArray(z.transform.matrix),F.matrix.decompose(F.position,F.rotation,F.scale),F.matrixWorldNeedsUpdate=!0,F.jointRadius=z.radius;F.visible=z!==null}let U=X.joints["index-finger-tip"],E=X.joints["thumb-tip"],N=U.position.distanceTo(E.position),G=0.02,D=0.005;if(X.inputState.pinching&&N>G+D)X.inputState.pinching=!1,this.dispatchEvent({type:"pinchend",handedness:J.handedness,target:this});else if(!X.inputState.pinching&&N<=G-D)X.inputState.pinching=!0,this.dispatchEvent({type:"pinchstart",handedness:J.handedness,target:this})}else if(Y!==null&&J.gripSpace){if(W=Q.getPose(J.gripSpace,$),W!==null){if(Y.matrix.fromArray(W.transform.matrix),Y.matrix.decompose(Y.position,Y.rotation,Y.scale),Y.matrixWorldNeedsUpdate=!0,W.linearVelocity)Y.hasLinearVelocity=!0,Y.linearVelocity.copy(W.linearVelocity);else Y.hasLinearVelocity=!1;if(W.angularVelocity)Y.hasAngularVelocity=!0,Y.angularVelocity.copy(W.angularVelocity);else Y.hasAngularVelocity=!1;if(Y.eventsEnabled)Y.dispatchEvent({type:"gripUpdated",data:J,target:this})}}if(H!==null){if(Z=Q.getPose(J.targetRaySpace,$),Z===null&&W!==null)Z=W;if(Z!==null){if(H.matrix.fromArray(Z.transform.matrix),H.matrix.decompose(H.position,H.rotation,H.scale),H.matrixWorldNeedsUpdate=!0,Z.linearVelocity)H.hasLinearVelocity=!0,H.linearVelocity.copy(Z.linearVelocity);else H.hasLinearVelocity=!1;if(Z.angularVelocity)H.hasAngularVelocity=!0,H.angularVelocity.copy(Z.angularVelocity);else H.hasAngularVelocity=!1;this.dispatchEvent(oW)}}}if(H!==null)H.visible=Z!==null;if(Y!==null)Y.visible=W!==null;if(X!==null)X.visible=K!==null;return this}_getHandJoint(J,Q){if(J.joints[Q.jointName]===void 0){let $=new I9;$.matrixAutoUpdate=!1,$.visible=!1,J.joints[Q.jointName]=$,J.add($)}return J.joints[Q.jointName]}}var vZ={aliceblue:15792383,antiquewhite:16444375,aqua:65535,aquamarine:8388564,azure:15794175,beige:16119260,bisque:16770244,black:0,blanchedalmond:16772045,blue:255,blueviolet:9055202,brown:10824234,burlywood:14596231,cadetblue:6266528,chartreuse:8388352,chocolate:13789470,coral:16744272,cornflowerblue:6591981,cornsilk:16775388,crimson:14423100,cyan:65535,darkblue:139,darkcyan:35723,darkgoldenrod:12092939,darkgray:11119017,darkgreen:25600,darkgrey:11119017,darkkhaki:12433259,darkmagenta:9109643,darkolivegreen:5597999,darkorange:16747520,darkorchid:10040012,darkred:9109504,darksalmon:15308410,darkseagreen:9419919,darkslateblue:4734347,darkslategray:3100495,darkslategrey:3100495,darkturquoise:52945,darkviolet:9699539,deeppink:16716947,deepskyblue:49151,dimgray:6908265,dimgrey:6908265,dodgerblue:2003199,firebrick:11674146,floralwhite:16775920,forestgreen:2263842,fuchsia:16711935,gainsboro:14474460,ghostwhite:16316671,gold:16766720,goldenrod:14329120,gray:8421504,green:32768,greenyellow:11403055,grey:8421504,honeydew:15794160,hotpink:16738740,indianred:13458524,indigo:4915330,ivory:16777200,khaki:15787660,lavender:15132410,lavenderblush:16773365,lawngreen:8190976,lemonchiffon:16775885,lightblue:11393254,lightcoral:15761536,lightcyan:14745599,lightgoldenrodyellow:16448210,lightgray:13882323,lightgreen:9498256,lightgrey:13882323,lightpink:16758465,lightsalmon:16752762,lightseagreen:2142890,lightskyblue:8900346,lightslategray:7833753,lightslategrey:7833753,lightsteelblue:11584734,lightyellow:16777184,lime:65280,limegreen:3329330,linen:16445670,magenta:16711935,maroon:8388608,mediumaquamarine:6737322,mediumblue:205,mediumorchid:12211667,mediumpurple:9662683,mediumseagreen:3978097,mediumslateblue:8087790,mediumspringgreen:64154,mediumturquoise:4772300,mediumvioletred:13047173,midnightblue:1644912,mintcream:16121850,mistyrose:16770273,moccasin:16770229,navajowhite:16768685,navy:128,oldlace:16643558,olive:8421376,olivedrab:7048739,orange:16753920,orangered:16729344,orchid:14315734,palegoldenrod:15657130,palegreen:10025880,paleturquoise:11529966,palevioletred:14381203,papayawhip:16773077,peachpuff:16767673,peru:13468991,pink:16761035,plum:14524637,powderblue:11591910,purple:8388736,rebeccapurple:6697881,red:16711680,rosybrown:12357519,royalblue:4286945,saddlebrown:9127187,salmon:16416882,sandybrown:16032864,seagreen:3050327,seashell:16774638,sienna:10506797,silver:12632256,skyblue:8900331,slateblue:6970061,slategray:7372944,slategrey:7372944,snow:16775930,springgreen:65407,steelblue:4620980,tan:13808780,teal:32896,thistle:14204888,tomato:16737095,turquoise:4251856,violet:15631086,wheat:16113331,white:16777215,whitesmoke:16119285,yellow:16776960,yellowgreen:10145074},M9={h:0,s:0,l:0},u8={h:0,s:0,l:0};function t6(J,Q,$){if($<0)$+=1;if($>1)$-=1;if($<0.16666666666666666)return J+(Q-J)*6*$;if($<0.5)return Q;if($<0.6666666666666666)return J+(Q-J)*6*(0.6666666666666666-$);return J}class g0{constructor(J,Q,$){return this.isColor=!0,this.r=1,this.g=1,this.b=1,this.set(J,Q,$)}set(J,Q,$){if(Q===void 0&&$===void 0){let Z=J;if(Z&&Z.isColor)this.copy(Z);else if(typeof Z==="number")this.setHex(Z);else if(typeof Z==="string")this.setStyle(Z)}else this.setRGB(J,Q,$);return this}setScalar(J){return this.r=J,this.g=J,this.b=J,this}setHex(J,Q="srgb"){return J=Math.floor(J),this.r=(J>>16&255)/255,this.g=(J>>8&255)/255,this.b=(J&255)/255,h0.colorSpaceToWorking(this,Q),this}setRGB(J,Q,$,Z=h0.workingColorSpace){return this.r=J,this.g=Q,this.b=$,h0.colorSpaceToWorking(this,Z),this}setHSL(J,Q,$,Z=h0.workingColorSpace){if(J=gW(J,1),Q=x0(Q,0,1),$=x0($,0,1),Q===0)this.r=this.g=this.b=$;else{let W=$<=0.5?$*(1+Q):$+Q-$*Q,K=2*$-W;this.r=t6(K,W,J+0.3333333333333333),this.g=t6(K,W,J),this.b=t6(K,W,J-0.3333333333333333)}return h0.colorSpaceToWorking(this,Z),this}setStyle(J,Q="srgb"){function $(W){if(W===void 0)return;if(parseFloat(W)<1)C0("Color: Alpha component of "+J+" will be ignored.")}let Z;if(Z=/^(\w+)\(([^\)]*)\)/.exec(J)){let W,K=Z[1],H=Z[2];switch(K){case"rgb":case"rgba":if(W=/^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(H))return $(W[4]),this.setRGB(Math.min(255,parseInt(W[1],10))/255,Math.min(255,parseInt(W[2],10))/255,Math.min(255,parseInt(W[3],10))/255,Q);if(W=/^\s*(\d+)\%\s*,\s*(\d+)\%\s*,\s*(\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(H))return $(W[4]),this.setRGB(Math.min(100,parseInt(W[1],10))/100,Math.min(100,parseInt(W[2],10))/100,Math.min(100,parseInt(W[3],10))/100,Q);break;case"hsl":case"hsla":if(W=/^\s*(\d*\.?\d+)\s*,\s*(\d*\.?\d+)\%\s*,\s*(\d*\.?\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(H))return $(W[4]),this.setHSL(parseFloat(W[1])/360,parseFloat(W[2])/100,parseFloat(W[3])/100,Q);break;default:C0("Color: Unknown color model "+J)}}else if(Z=/^\#([A-Fa-f\d]+)$/.exec(J)){let W=Z[1],K=W.length;if(K===3)return this.setRGB(parseInt(W.charAt(0),16)/15,parseInt(W.charAt(1),16)/15,parseInt(W.charAt(2),16)/15,Q);else if(K===6)return this.setHex(parseInt(W,16),Q);else C0("Color: Invalid hex color "+J)}else if(J&&J.length>0)return this.setColorName(J,Q);return this}setColorName(J,Q="srgb"){let $=vZ[J.toLowerCase()];if($!==void 0)this.setHex($,Q);else C0("Color: Unknown color "+J);return this}clone(){return new this.constructor(this.r,this.g,this.b)}copy(J){return this.r=J.r,this.g=J.g,this.b=J.b,this}copySRGBToLinear(J){return this.r=U9(J.r),this.g=U9(J.g),this.b=U9(J.b),this}copyLinearToSRGB(J){return this.r=U8(J.r),this.g=U8(J.g),this.b=U8(J.b),this}convertSRGBToLinear(){return this.copySRGBToLinear(this),this}convertLinearToSRGB(){return this.copyLinearToSRGB(this),this}getHex(J="srgb"){return h0.workingToColorSpace(LJ.copy(this),J),Math.round(x0(LJ.r*255,0,255))*65536+Math.round(x0(LJ.g*255,0,255))*256+Math.round(x0(LJ.b*255,0,255))}getHexString(J="srgb"){return("000000"+this.getHex(J).toString(16)).slice(-6)}getHSL(J,Q=h0.workingColorSpace){h0.workingToColorSpace(LJ.copy(this),Q);let{r:$,g:Z,b:W}=LJ,K=Math.max($,Z,W),H=Math.min($,Z,W),Y,X,U=(H+K)/2;if(H===K)Y=0,X=0;else{let E=K-H;switch(X=U<=0.5?E/(K+H):E/(2-K-H),K){case $:Y=(Z-W)/E+(Z<W?6:0);break;case Z:Y=(W-$)/E+2;break;case W:Y=($-Z)/E+4;break}Y/=6}return J.h=Y,J.s=X,J.l=U,J}getRGB(J,Q=h0.workingColorSpace){return h0.workingToColorSpace(LJ.copy(this),Q),J.r=LJ.r,J.g=LJ.g,J.b=LJ.b,J}getStyle(J="srgb"){h0.workingToColorSpace(LJ.copy(this),J);let{r:Q,g:$,b:Z}=LJ;if(J!=="srgb")return`color(${J} ${Q.toFixed(3)} ${$.toFixed(3)} ${Z.toFixed(3)})`;return`rgb(${Math.round(Q*255)},${Math.round($*255)},${Math.round(Z*255)})`}offsetHSL(J,Q,$){return this.getHSL(M9),this.setHSL(M9.h+J,M9.s+Q,M9.l+$)}add(J){return this.r+=J.r,this.g+=J.g,this.b+=J.b,this}addColors(J,Q){return this.r=J.r+Q.r,this.g=J.g+Q.g,this.b=J.b+Q.b,this}addScalar(J){return this.r+=J,this.g+=J,this.b+=J,this}sub(J){return this.r=Math.max(0,this.r-J.r),this.g=Math.max(0,this.g-J.g),this.b=Math.max(0,this.b-J.b),this}multiply(J){return this.r*=J.r,this.g*=J.g,this.b*=J.b,this}multiplyScalar(J){return this.r*=J,this.g*=J,this.b*=J,this}lerp(J,Q){return this.r+=(J.r-this.r)*Q,this.g+=(J.g-this.g)*Q,this.b+=(J.b-this.b)*Q,this}lerpColors(J,Q,$){return this.r=J.r+(Q.r-J.r)*$,this.g=J.g+(Q.g-J.g)*$,this.b=J.b+(Q.b-J.b)*$,this}lerpHSL(J,Q){this.getHSL(M9),J.getHSL(u8);let $=n6(M9.h,u8.h,Q),Z=n6(M9.s,u8.s,Q),W=n6(M9.l,u8.l,Q);return this.setHSL($,Z,W),this}setFromVector3(J){return this.r=J.x,this.g=J.y,this.b=J.z,this}applyMatrix3(J){let Q=this.r,$=this.g,Z=this.b,W=J.elements;return this.r=W[0]*Q+W[3]*$+W[6]*Z,this.g=W[1]*Q+W[4]*$+W[7]*Z,this.b=W[2]*Q+W[5]*$+W[8]*Z,this}equals(J){return J.r===this.r&&J.g===this.g&&J.b===this.b}fromArray(J,Q=0){return this.r=J[Q],this.g=J[Q+1],this.b=J[Q+2],this}toArray(J=[],Q=0){return J[Q]=this.r,J[Q+1]=this.g,J[Q+2]=this.b,J}fromBufferAttribute(J,Q){return this.r=J.getX(Q),this.g=J.getY(Q),this.b=J.getZ(Q),this}toJSON(){return this.getHex()}*[Symbol.iterator](){yield this.r,yield this.g,yield this.b}}var LJ=new g0;g0.NAMES=vZ;class A6 extends BJ{constructor(){super();if(this.isScene=!0,this.type="Scene",this.background=null,this.environment=null,this.fog=null,this.backgroundBlurriness=0,this.backgroundIntensity=1,this.backgroundRotation=new A9,this.environmentIntensity=1,this.environmentRotation=new A9,this.overrideMaterial=null,typeof __THREE_DEVTOOLS__<"u")__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}copy(J,Q){if(super.copy(J,Q),J.background!==null)this.background=J.background.clone();if(J.environment!==null)this.environment=J.environment.clone();if(J.fog!==null)this.fog=J.fog.clone();if(this.backgroundBlurriness=J.backgroundBlurriness,this.backgroundIntensity=J.backgroundIntensity,this.backgroundRotation.copy(J.backgroundRotation),this.environmentIntensity=J.environmentIntensity,this.environmentRotation.copy(J.environmentRotation),J.overrideMaterial!==null)this.overrideMaterial=J.overrideMaterial.clone();return this.matrixAutoUpdate=J.matrixAutoUpdate,this}toJSON(J){let Q=super.toJSON(J);if(this.fog!==null)Q.object.fog=this.fog.toJSON();if(this.backgroundBlurriness>0)Q.object.backgroundBlurriness=this.backgroundBlurriness;if(this.backgroundIntensity!==1)Q.object.backgroundIntensity=this.backgroundIntensity;if(Q.object.backgroundRotation=this.backgroundRotation.toArray(),this.environmentIntensity!==1)Q.object.environmentIntensity=this.environmentIntensity;return Q.object.environmentRotation=this.environmentRotation.toArray(),Q}}var dJ=new b,W9=new b,e6=new b,K9=new b,Q8=new b,$8=new b,I$=new b,J7=new b,Q7=new b,$7=new b,Z7=new KJ,W7=new KJ,K7=new KJ;class hJ{constructor(J=new b,Q=new b,$=new b){this.a=J,this.b=Q,this.c=$}static getNormal(J,Q,$,Z){Z.subVectors($,Q),dJ.subVectors(J,Q),Z.cross(dJ);let W=Z.lengthSq();if(W>0)return Z.multiplyScalar(1/Math.sqrt(W));return Z.set(0,0,0)}static getBarycoord(J,Q,$,Z,W){dJ.subVectors(Z,Q),W9.subVectors($,Q),e6.subVectors(J,Q);let K=dJ.dot(dJ),H=dJ.dot(W9),Y=dJ.dot(e6),X=W9.dot(W9),U=W9.dot(e6),E=K*X-H*H;if(E===0)return W.set(0,0,0),null;let N=1/E,G=(X*Y-H*U)*N,D=(K*U-H*Y)*N;return W.set(1-G-D,D,G)}static containsPoint(J,Q,$,Z){if(this.getBarycoord(J,Q,$,Z,K9)===null)return!1;return K9.x>=0&&K9.y>=0&&K9.x+K9.y<=1}static getInterpolation(J,Q,$,Z,W,K,H,Y){if(this.getBarycoord(J,Q,$,Z,K9)===null){if(Y.x=0,Y.y=0,"z"in Y)Y.z=0;if("w"in Y)Y.w=0;return null}return Y.setScalar(0),Y.addScaledVector(W,K9.x),Y.addScaledVector(K,K9.y),Y.addScaledVector(H,K9.z),Y}static getInterpolatedAttribute(J,Q,$,Z,W,K){return Z7.setScalar(0),W7.setScalar(0),K7.setScalar(0),Z7.fromBufferAttribute(J,Q),W7.fromBufferAttribute(J,$),K7.fromBufferAttribute(J,Z),K.setScalar(0),K.addScaledVector(Z7,W.x),K.addScaledVector(W7,W.y),K.addScaledVector(K7,W.z),K}static isFrontFacing(J,Q,$,Z){return dJ.subVectors($,Q),W9.subVectors(J,Q),dJ.cross(W9).dot(Z)<0}set(J,Q,$){return this.a.copy(J),this.b.copy(Q),this.c.copy($),this}setFromPointsAndIndices(J,Q,$,Z){return this.a.copy(J[Q]),this.b.copy(J[$]),this.c.copy(J[Z]),this}setFromAttributeAndIndices(J,Q,$,Z){return this.a.fromBufferAttribute(J,Q),this.b.fromBufferAttribute(J,$),this.c.fromBufferAttribute(J,Z),this}clone(){return new this.constructor().copy(this)}copy(J){return this.a.copy(J.a),this.b.copy(J.b),this.c.copy(J.c),this}getArea(){return dJ.subVectors(this.c,this.b),W9.subVectors(this.a,this.b),dJ.cross(W9).length()*0.5}getMidpoint(J){return J.addVectors(this.a,this.b).add(this.c).multiplyScalar(0.3333333333333333)}getNormal(J){return hJ.getNormal(this.a,this.b,this.c,J)}getPlane(J){return J.setFromCoplanarPoints(this.a,this.b,this.c)}getBarycoord(J,Q){return hJ.getBarycoord(J,this.a,this.b,this.c,Q)}getInterpolation(J,Q,$,Z,W){return hJ.getInterpolation(J,this.a,this.b,this.c,Q,$,Z,W)}containsPoint(J){return hJ.containsPoint(J,this.a,this.b,this.c)}isFrontFacing(J){return hJ.isFrontFacing(this.a,this.b,this.c,J)}intersectsBox(J){return J.intersectsTriangle(this)}closestPointToPoint(J,Q){let $=this.a,Z=this.b,W=this.c,K,H;Q8.subVectors(Z,$),$8.subVectors(W,$),J7.subVectors(J,$);let Y=Q8.dot(J7),X=$8.dot(J7);if(Y<=0&&X<=0)return Q.copy($);Q7.subVectors(J,Z);let U=Q8.dot(Q7),E=$8.dot(Q7);if(U>=0&&E<=U)return Q.copy(Z);let N=Y*E-U*X;if(N<=0&&Y>=0&&U<=0)return K=Y/(Y-U),Q.copy($).addScaledVector(Q8,K);$7.subVectors(J,W);let G=Q8.dot($7),D=$8.dot($7);if(D>=0&&G<=D)return Q.copy(W);let M=G*X-Y*D;if(M<=0&&X>=0&&D<=0)return H=X/(X-D),Q.copy($).addScaledVector($8,H);let z=U*D-G*E;if(z<=0&&E-U>=0&&G-D>=0)return I$.subVectors(W,Z),H=(E-U)/(E-U+(G-D)),Q.copy(Z).addScaledVector(I$,H);let F=1/(z+M+N);return K=M*F,H=N*F,Q.copy($).addScaledVector(Q8,K).addScaledVector($8,H)}equals(J){return J.a.equals(this.a)&&J.b.equals(this.b)&&J.c.equals(this.c)}}class d9{constructor(J=new b(1/0,1/0,1/0),Q=new b(-1/0,-1/0,-1/0)){this.isBox3=!0,this.min=J,this.max=Q}set(J,Q){return this.min.copy(J),this.max.copy(Q),this}setFromArray(J){this.makeEmpty();for(let Q=0,$=J.length;Q<$;Q+=3)this.expandByPoint(lJ.fromArray(J,Q));return this}setFromBufferAttribute(J){this.makeEmpty();for(let Q=0,$=J.count;Q<$;Q++)this.expandByPoint(lJ.fromBufferAttribute(J,Q));return this}setFromPoints(J){this.makeEmpty();for(let Q=0,$=J.length;Q<$;Q++)this.expandByPoint(J[Q]);return this}setFromCenterAndSize(J,Q){let $=lJ.copy(Q).multiplyScalar(0.5);return this.min.copy(J).sub($),this.max.copy(J).add($),this}setFromObject(J,Q=!1){return this.makeEmpty(),this.expandByObject(J,Q)}clone(){return new this.constructor().copy(this)}copy(J){return this.min.copy(J.min),this.max.copy(J.max),this}makeEmpty(){return this.min.x=this.min.y=this.min.z=1/0,this.max.x=this.max.y=this.max.z=-1/0,this}isEmpty(){return this.max.x<this.min.x||this.max.y<this.min.y||this.max.z<this.min.z}getCenter(J){return this.isEmpty()?J.set(0,0,0):J.addVectors(this.min,this.max).multiplyScalar(0.5)}getSize(J){return this.isEmpty()?J.set(0,0,0):J.subVectors(this.max,this.min)}expandByPoint(J){return this.min.min(J),this.max.max(J),this}expandByVector(J){return this.min.sub(J),this.max.add(J),this}expandByScalar(J){return this.min.addScalar(-J),this.max.addScalar(J),this}expandByObject(J,Q=!1){J.updateWorldMatrix(!1,!1);let $=J.geometry;if($!==void 0){let W=$.getAttribute("position");if(Q===!0&&W!==void 0&&J.isInstancedMesh!==!0)for(let K=0,H=W.count;K<H;K++){if(J.isMesh===!0)J.getVertexPosition(K,lJ);else lJ.fromBufferAttribute(W,K);lJ.applyMatrix4(J.matrixWorld),this.expandByPoint(lJ)}else{if(J.boundingBox!==void 0){if(J.boundingBox===null)J.computeBoundingBox();c8.copy(J.boundingBox)}else{if($.boundingBox===null)$.computeBoundingBox();c8.copy($.boundingBox)}c8.applyMatrix4(J.matrixWorld),this.union(c8)}}let Z=J.children;for(let W=0,K=Z.length;W<K;W++)this.expandByObject(Z[W],Q);return this}containsPoint(J){return J.x>=this.min.x&&J.x<=this.max.x&&J.y>=this.min.y&&J.y<=this.max.y&&J.z>=this.min.z&&J.z<=this.max.z}containsBox(J){return this.min.x<=J.min.x&&J.max.x<=this.max.x&&this.min.y<=J.min.y&&J.max.y<=this.max.y&&this.min.z<=J.min.z&&J.max.z<=this.max.z}getParameter(J,Q){return Q.set((J.x-this.min.x)/(this.max.x-this.min.x),(J.y-this.min.y)/(this.max.y-this.min.y),(J.z-this.min.z)/(this.max.z-this.min.z))}intersectsBox(J){return J.max.x>=this.min.x&&J.min.x<=this.max.x&&J.max.y>=this.min.y&&J.min.y<=this.max.y&&J.max.z>=this.min.z&&J.min.z<=this.max.z}intersectsSphere(J){return this.clampPoint(J.center,lJ),lJ.distanceToSquared(J.center)<=J.radius*J.radius}intersectsPlane(J){let Q,$;if(J.normal.x>0)Q=J.normal.x*this.min.x,$=J.normal.x*this.max.x;else Q=J.normal.x*this.max.x,$=J.normal.x*this.min.x;if(J.normal.y>0)Q+=J.normal.y*this.min.y,$+=J.normal.y*this.max.y;else Q+=J.normal.y*this.max.y,$+=J.normal.y*this.min.y;if(J.normal.z>0)Q+=J.normal.z*this.min.z,$+=J.normal.z*this.max.z;else Q+=J.normal.z*this.max.z,$+=J.normal.z*this.min.z;return Q<=-J.constant&&$>=-J.constant}intersectsTriangle(J){if(this.isEmpty())return!1;this.getCenter(B8),n8.subVectors(this.max,B8),Z8.subVectors(J.a,B8),W8.subVectors(J.b,B8),K8.subVectors(J.c,B8),L9.subVectors(W8,Z8),V9.subVectors(K8,W8),S9.subVectors(Z8,K8);let Q=[0,-L9.z,L9.y,0,-V9.z,V9.y,0,-S9.z,S9.y,L9.z,0,-L9.x,V9.z,0,-V9.x,S9.z,0,-S9.x,-L9.y,L9.x,0,-V9.y,V9.x,0,-S9.y,S9.x,0];if(!H7(Q,Z8,W8,K8,n8))return!1;if(Q=[1,0,0,0,1,0,0,0,1],!H7(Q,Z8,W8,K8,n8))return!1;return s8.crossVectors(L9,V9),Q=[s8.x,s8.y,s8.z],H7(Q,Z8,W8,K8,n8)}clampPoint(J,Q){return Q.copy(J).clamp(this.min,this.max)}distanceToPoint(J){return this.clampPoint(J,lJ).distanceTo(J)}getBoundingSphere(J){if(this.isEmpty())J.makeEmpty();else this.getCenter(J.center),J.radius=this.getSize(lJ).length()*0.5;return J}intersect(J){if(this.min.max(J.min),this.max.min(J.max),this.isEmpty())this.makeEmpty();return this}union(J){return this.min.min(J.min),this.max.max(J.max),this}applyMatrix4(J){if(this.isEmpty())return this;return H9[0].set(this.min.x,this.min.y,this.min.z).applyMatrix4(J),H9[1].set(this.min.x,this.min.y,this.max.z).applyMatrix4(J),H9[2].set(this.min.x,this.max.y,this.min.z).applyMatrix4(J),H9[3].set(this.min.x,this.max.y,this.max.z).applyMatrix4(J),H9[4].set(this.max.x,this.min.y,this.min.z).applyMatrix4(J),H9[5].set(this.max.x,this.min.y,this.max.z).applyMatrix4(J),H9[6].set(this.max.x,this.max.y,this.min.z).applyMatrix4(J),H9[7].set(this.max.x,this.max.y,this.max.z).applyMatrix4(J),this.setFromPoints(H9),this}translate(J){return this.min.add(J),this.max.add(J),this}equals(J){return J.min.equals(this.min)&&J.max.equals(this.max)}toJSON(){return{min:this.min.toArray(),max:this.max.toArray()}}fromJSON(J){return this.min.fromArray(J.min),this.max.fromArray(J.max),this}}var H9=[new b,new b,new b,new b,new b,new b,new b,new b],lJ=new b,c8=new d9,Z8=new b,W8=new b,K8=new b,L9=new b,V9=new b,S9=new b,B8=new b,n8=new b,s8=new b,j9=new b;function H7(J,Q,$,Z,W){for(let K=0,H=J.length-3;K<=H;K+=3){j9.fromArray(J,K);let Y=W.x*Math.abs(j9.x)+W.y*Math.abs(j9.y)+W.z*Math.abs(j9.z),X=Q.dot(j9),U=$.dot(j9),E=Z.dot(j9);if(Math.max(-Math.max(X,U,E),Math.min(X,U,E))>Y)return!1}return!0}var GJ=new b,i8=new u0,aW=0;class wJ extends N9{constructor(J,Q,$=!1){super();if(Array.isArray(J))throw TypeError("THREE.BufferAttribute: array should be a Typed Array.");this.isBufferAttribute=!0,Object.defineProperty(this,"id",{value:aW++}),this.name="",this.array=J,this.itemSize=Q,this.count=J!==void 0?J.length/Q:0,this.normalized=$,this.usage=35044,this.updateRanges=[],this.gpuType=1015,this.version=0}onUploadCallback(){}set needsUpdate(J){if(J===!0)this.version++}setUsage(J){return this.usage=J,this}addUpdateRange(J,Q){this.updateRanges.push({start:J,count:Q})}clearUpdateRanges(){this.updateRanges.length=0}copy(J){return this.name=J.name,this.array=new J.array.constructor(J.array),this.itemSize=J.itemSize,this.count=J.count,this.normalized=J.normalized,this.usage=J.usage,this.gpuType=J.gpuType,this}copyAt(J,Q,$){J*=this.itemSize,$*=Q.itemSize;for(let Z=0,W=this.itemSize;Z<W;Z++)this.array[J+Z]=Q.array[$+Z];return this}copyArray(J){return this.array.set(J),this}applyMatrix3(J){if(this.itemSize===2)for(let Q=0,$=this.count;Q<$;Q++)i8.fromBufferAttribute(this,Q),i8.applyMatrix3(J),this.setXY(Q,i8.x,i8.y);else if(this.itemSize===3)for(let Q=0,$=this.count;Q<$;Q++)GJ.fromBufferAttribute(this,Q),GJ.applyMatrix3(J),this.setXYZ(Q,GJ.x,GJ.y,GJ.z);return this}applyMatrix4(J){for(let Q=0,$=this.count;Q<$;Q++)GJ.fromBufferAttribute(this,Q),GJ.applyMatrix4(J),this.setXYZ(Q,GJ.x,GJ.y,GJ.z);return this}applyNormalMatrix(J){for(let Q=0,$=this.count;Q<$;Q++)GJ.fromBufferAttribute(this,Q),GJ.applyNormalMatrix(J),this.setXYZ(Q,GJ.x,GJ.y,GJ.z);return this}transformDirection(J){for(let Q=0,$=this.count;Q<$;Q++)GJ.fromBufferAttribute(this,Q),GJ.transformDirection(J),this.setXYZ(Q,GJ.x,GJ.y,GJ.z);return this}set(J,Q=0){return this.array.set(J,Q),this}getComponent(J,Q){let $=this.array[J*this.itemSize+Q];if(this.normalized)$=L8($,this.array);return $}setComponent(J,Q,$){if(this.normalized)$=AJ($,this.array);return this.array[J*this.itemSize+Q]=$,this}getX(J){let Q=this.array[J*this.itemSize];if(this.normalized)Q=L8(Q,this.array);return Q}setX(J,Q){if(this.normalized)Q=AJ(Q,this.array);return this.array[J*this.itemSize]=Q,this}getY(J){let Q=this.array[J*this.itemSize+1];if(this.normalized)Q=L8(Q,this.array);return Q}setY(J,Q){if(this.normalized)Q=AJ(Q,this.array);return this.array[J*this.itemSize+1]=Q,this}getZ(J){let Q=this.array[J*this.itemSize+2];if(this.normalized)Q=L8(Q,this.array);return Q}setZ(J,Q){if(this.normalized)Q=AJ(Q,this.array);return this.array[J*this.itemSize+2]=Q,this}getW(J){let Q=this.array[J*this.itemSize+3];if(this.normalized)Q=L8(Q,this.array);return Q}setW(J,Q){if(this.normalized)Q=AJ(Q,this.array);return this.array[J*this.itemSize+3]=Q,this}setXY(J,Q,$){if(J*=this.itemSize,this.normalized)Q=AJ(Q,this.array),$=AJ($,this.array);return this.array[J+0]=Q,this.array[J+1]=$,this}setXYZ(J,Q,$,Z){if(J*=this.itemSize,this.normalized)Q=AJ(Q,this.array),$=AJ($,this.array),Z=AJ(Z,this.array);return this.array[J+0]=Q,this.array[J+1]=$,this.array[J+2]=Z,this}setXYZW(J,Q,$,Z,W){if(J*=this.itemSize,this.normalized)Q=AJ(Q,this.array),$=AJ($,this.array),Z=AJ(Z,this.array),W=AJ(W,this.array);return this.array[J+0]=Q,this.array[J+1]=$,this.array[J+2]=Z,this.array[J+3]=W,this}onUpload(J){return this.onUploadCallback=J,this}clone(){return new this.constructor(this.array,this.itemSize).copy(this)}toJSON(){let J={itemSize:this.itemSize,type:this.array.constructor.name,array:Array.from(this.array),normalized:this.normalized};if(this.name!=="")J.name=this.name;if(this.usage!==35044)J.usage=this.usage;return J}dispose(){this.dispatchEvent({type:"dispose"})}}class w6 extends wJ{constructor(J,Q,$){super(new Uint16Array(J),Q,$)}}class C6 extends wJ{constructor(J,Q,$){super(new Uint32Array(J),Q,$)}}class uJ extends wJ{constructor(J,Q,$){super(new Float32Array(J),Q,$)}}var rW=new d9,z8=new b,Y7=new b;class R8{constructor(J=new b,Q=-1){this.isSphere=!0,this.center=J,this.radius=Q}set(J,Q){return this.center.copy(J),this.radius=Q,this}setFromPoints(J,Q){let $=this.center;if(Q!==void 0)$.copy(Q);else rW.setFromPoints(J).getCenter($);let Z=0;for(let W=0,K=J.length;W<K;W++)Z=Math.max(Z,$.distanceToSquared(J[W]));return this.radius=Math.sqrt(Z),this}copy(J){return this.center.copy(J.center),this.radius=J.radius,this}isEmpty(){return this.radius<0}makeEmpty(){return this.center.set(0,0,0),this.radius=-1,this}containsPoint(J){return J.distanceToSquared(this.center)<=this.radius*this.radius}distanceToPoint(J){return J.distanceTo(this.center)-this.radius}intersectsSphere(J){let Q=this.radius+J.radius;return J.center.distanceToSquared(this.center)<=Q*Q}intersectsBox(J){return J.intersectsSphere(this)}intersectsPlane(J){return Math.abs(J.distanceToPoint(this.center))<=this.radius}clampPoint(J,Q){let $=this.center.distanceToSquared(J);if(Q.copy(J),$>this.radius*this.radius)Q.sub(this.center).normalize(),Q.multiplyScalar(this.radius).add(this.center);return Q}getBoundingBox(J){if(this.isEmpty())return J.makeEmpty(),J;return J.set(this.center,this.center),J.expandByScalar(this.radius),J}applyMatrix4(J){return this.center.applyMatrix4(J),this.radius=this.radius*J.getMaxScaleOnAxis(),this}translate(J){return this.center.add(J),this}expandByPoint(J){if(this.isEmpty())return this.center.copy(J),this.radius=0,this;z8.subVectors(J,this.center);let Q=z8.lengthSq();if(Q>this.radius*this.radius){let $=Math.sqrt(Q),Z=($-this.radius)*0.5;this.center.addScaledVector(z8,Z/$),this.radius+=Z}return this}union(J){if(J.isEmpty())return this;if(this.isEmpty())return this.copy(J),this;if(this.center.equals(J.center)===!0)this.radius=Math.max(this.radius,J.radius);else Y7.subVectors(J.center,this.center).setLength(J.radius),this.expandByPoint(z8.copy(J.center).add(Y7)),this.expandByPoint(z8.copy(J.center).sub(Y7));return this}equals(J){return J.center.equals(this.center)&&J.radius===this.radius}clone(){return new this.constructor().copy(this)}toJSON(){return{radius:this.radius,center:this.center.toArray()}}fromJSON(J){return this.radius=J.radius,this.center.fromArray(J.center),this}}var tW=0,bJ=new WJ,X7=new BJ,H8=new b,SJ=new d9,I8=new d9,RJ=new b;class jJ extends N9{constructor(){super();this.isBufferGeometry=!0,Object.defineProperty(this,"id",{value:tW++}),this.uuid=S8(),this.name="",this.type="BufferGeometry",this.index=null,this.indirect=null,this.indirectOffset=0,this.attributes={},this.morphAttributes={},this.morphTargetsRelative=!1,this.groups=[],this.boundingBox=null,this.boundingSphere=null,this.drawRange={start:0,count:1/0},this.userData={},this._transformed=!1}getIndex(){return this.index}setIndex(J){if(Array.isArray(J))this.index=new((hW(J))?C6:w6)(J,1);else this.index=J;return this}setIndirect(J,Q=0){return this.indirect=J,this.indirectOffset=Q,this}getIndirect(){return this.indirect}getAttribute(J){return this.attributes[J]}setAttribute(J,Q){return this.attributes[J]=Q,this}deleteAttribute(J){return delete this.attributes[J],this}hasAttribute(J){return this.attributes[J]!==void 0}addGroup(J,Q,$=0){this.groups.push({start:J,count:Q,materialIndex:$})}clearGroups(){this.groups=[]}setDrawRange(J,Q){this.drawRange.start=J,this.drawRange.count=Q}applyMatrix4(J){let Q=this.attributes.position;if(Q!==void 0)Q.applyMatrix4(J),Q.needsUpdate=!0;let $=this.attributes.normal;if($!==void 0){let W=new P0().getNormalMatrix(J);$.applyNormalMatrix(W),$.needsUpdate=!0}let Z=this.attributes.tangent;if(Z!==void 0)Z.transformDirection(J),Z.needsUpdate=!0;if(this.boundingBox!==null)this.computeBoundingBox();if(this.boundingSphere!==null)this.computeBoundingSphere();return this._transformed=!0,this}applyQuaternion(J){return bJ.makeRotationFromQuaternion(J),this.applyMatrix4(bJ),this}rotateX(J){return bJ.makeRotationX(J),this.applyMatrix4(bJ),this}rotateY(J){return bJ.makeRotationY(J),this.applyMatrix4(bJ),this}rotateZ(J){return bJ.makeRotationZ(J),this.applyMatrix4(bJ),this}translate(J,Q,$){return bJ.makeTranslation(J,Q,$),this.applyMatrix4(bJ),this}scale(J,Q,$){return bJ.makeScale(J,Q,$),this.applyMatrix4(bJ),this}lookAt(J){return X7.lookAt(J),X7.updateMatrix(),this.applyMatrix4(X7.matrix),this}center(){return this.computeBoundingBox(),this.boundingBox.getCenter(H8).negate(),this.translate(H8.x,H8.y,H8.z),this}setFromPoints(J){let Q=this.getAttribute("position");if(Q===void 0){let $=[];for(let Z=0,W=J.length;Z<W;Z++){let K=J[Z];$.push(K.x,K.y,K.z||0)}this.setAttribute("position",new uJ($,3))}else{let $=Math.min(J.length,Q.count);for(let Z=0;Z<$;Z++){let W=J[Z];Q.setXYZ(Z,W.x,W.y,W.z||0)}if(J.length>Q.count)C0("BufferGeometry: Buffer size too small for points data. Use .dispose() and create a new geometry.");Q.needsUpdate=!0}return this}computeBoundingBox(){if(this.boundingBox===null)this.boundingBox=new d9;let J=this.attributes.position,Q=this.morphAttributes.position;if(J&&J.isGLBufferAttribute){_0("BufferGeometry.computeBoundingBox(): GLBufferAttribute requires a manual bounding box.",this),this.boundingBox.set(new b(-1/0,-1/0,-1/0),new b(1/0,1/0,1/0));return}if(J!==void 0){if(this.boundingBox.setFromBufferAttribute(J),Q)for(let $=0,Z=Q.length;$<Z;$++){let W=Q[$];if(SJ.setFromBufferAttribute(W),this.morphTargetsRelative)RJ.addVectors(this.boundingBox.min,SJ.min),this.boundingBox.expandByPoint(RJ),RJ.addVectors(this.boundingBox.max,SJ.max),this.boundingBox.expandByPoint(RJ);else this.boundingBox.expandByPoint(SJ.min),this.boundingBox.expandByPoint(SJ.max)}}else this.boundingBox.makeEmpty();if(isNaN(this.boundingBox.min.x)||isNaN(this.boundingBox.min.y)||isNaN(this.boundingBox.min.z))_0('BufferGeometry.computeBoundingBox(): Computed min/max have NaN values. The "position" attribute is likely to have NaN values.',this)}computeBoundingSphere(){if(this.boundingSphere===null)this.boundingSphere=new R8;let J=this.attributes.position,Q=this.morphAttributes.position;if(J&&J.isGLBufferAttribute){_0("BufferGeometry.computeBoundingSphere(): GLBufferAttribute requires a manual bounding sphere.",this),this.boundingSphere.set(new b,1/0);return}if(J){let $=this.boundingSphere.center;if(SJ.setFromBufferAttribute(J),Q)for(let W=0,K=Q.length;W<K;W++){let H=Q[W];if(I8.setFromBufferAttribute(H),this.morphTargetsRelative)RJ.addVectors(SJ.min,I8.min),SJ.expandByPoint(RJ),RJ.addVectors(SJ.max,I8.max),SJ.expandByPoint(RJ);else SJ.expandByPoint(I8.min),SJ.expandByPoint(I8.max)}SJ.getCenter($);let Z=0;for(let W=0,K=J.count;W<K;W++)RJ.fromBufferAttribute(J,W),Z=Math.max(Z,$.distanceToSquared(RJ));if(Q)for(let W=0,K=Q.length;W<K;W++){let H=Q[W],Y=this.morphTargetsRelative;for(let X=0,U=H.count;X<U;X++){if(RJ.fromBufferAttribute(H,X),Y)H8.fromBufferAttribute(J,X),RJ.add(H8);Z=Math.max(Z,$.distanceToSquared(RJ))}}if(this.boundingSphere.radius=Math.sqrt(Z),isNaN(this.boundingSphere.radius))_0('BufferGeometry.computeBoundingSphere(): Computed radius is NaN. The "position" attribute is likely to have NaN values.',this)}}computeTangents(){let J=this.index,Q=this.attributes;if(J===null||Q.position===void 0||Q.normal===void 0||Q.uv===void 0){_0("BufferGeometry: .computeTangents() failed. Missing required attributes (index, position, normal or uv)");return}let{position:$,normal:Z,uv:W}=Q,K=this.getAttribute("tangent");if(K===void 0||K.count!==$.count)K=new wJ(new Float32Array(4*$.count),4),this.setAttribute("tangent",K);let H=[],Y=[];for(let P=0;P<$.count;P++)H[P]=new b,Y[P]=new b;let X=new b,U=new b,E=new b,N=new u0,G=new u0,D=new u0,M=new b,z=new b;function F(P,O,B){X.fromBufferAttribute($,P),U.fromBufferAttribute($,O),E.fromBufferAttribute($,B),N.fromBufferAttribute(W,P),G.fromBufferAttribute(W,O),D.fromBufferAttribute(W,B),U.sub(X),E.sub(X),G.sub(N),D.sub(N);let l=1/(G.x*D.y-D.x*G.y);if(!isFinite(l))return;M.copy(U).multiplyScalar(D.y).addScaledVector(E,-G.y).multiplyScalar(l),z.copy(E).multiplyScalar(G.x).addScaledVector(U,-D.x).multiplyScalar(l),H[P].add(M),H[O].add(M),H[B].add(M),Y[P].add(z),Y[O].add(z),Y[B].add(z)}let q=this.groups;if(q.length===0)q=[{start:0,count:J.count}];for(let P=0,O=q.length;P<O;++P){let B=q[P],l=B.start,C=B.count;for(let m=l,o=l+C;m<o;m+=3)F(J.getX(m+0),J.getX(m+1),J.getX(m+2))}let _=new b,w=new b,V=new b,A=new b;function I(P){V.fromBufferAttribute(Z,P),A.copy(V);let O=H[P];_.copy(O),_.sub(V.multiplyScalar(V.dot(O))).normalize(),w.crossVectors(A,O);let l=w.dot(Y[P])<0?-1:1;K.setXYZW(P,_.x,_.y,_.z,l)}for(let P=0,O=q.length;P<O;++P){let B=q[P],l=B.start,C=B.count;for(let m=l,o=l+C;m<o;m+=3)I(J.getX(m+0)),I(J.getX(m+1)),I(J.getX(m+2))}this._transformed=!0}computeVertexNormals(){let J=this.index,Q=this.getAttribute("position");if(Q!==void 0){let $=this.getAttribute("normal");if($===void 0||$.count!==Q.count)$=new wJ(new Float32Array(Q.count*3),3),this.setAttribute("normal",$);else for(let N=0,G=$.count;N<G;N++)$.setXYZ(N,0,0,0);let Z=new b,W=new b,K=new b,H=new b,Y=new b,X=new b,U=new b,E=new b;if(J)for(let N=0,G=J.count;N<G;N+=3){let D=J.getX(N+0),M=J.getX(N+1),z=J.getX(N+2);Z.fromBufferAttribute(Q,D),W.fromBufferAttribute(Q,M),K.fromBufferAttribute(Q,z),U.subVectors(K,W),E.subVectors(Z,W),U.cross(E),H.fromBufferAttribute($,D),Y.fromBufferAttribute($,M),X.fromBufferAttribute($,z),H.add(U),Y.add(U),X.add(U),$.setXYZ(D,H.x,H.y,H.z),$.setXYZ(M,Y.x,Y.y,Y.z),$.setXYZ(z,X.x,X.y,X.z)}else for(let N=0,G=Q.count;N<G;N+=3)Z.fromBufferAttribute(Q,N+0),W.fromBufferAttribute(Q,N+1),K.fromBufferAttribute(Q,N+2),U.subVectors(K,W),E.subVectors(Z,W),U.cross(E),$.setXYZ(N+0,U.x,U.y,U.z),$.setXYZ(N+1,U.x,U.y,U.z),$.setXYZ(N+2,U.x,U.y,U.z);this.normalizeNormals(),$.needsUpdate=!0}}normalizeNormals(){let J=this.attributes.normal;for(let Q=0,$=J.count;Q<$;Q++)RJ.fromBufferAttribute(J,Q),RJ.normalize(),J.setXYZ(Q,RJ.x,RJ.y,RJ.z)}toNonIndexed(){function J(H,Y){let{array:X,itemSize:U,normalized:E}=H,N=new X.constructor(Y.length*U),G=0,D=0;for(let M=0,z=Y.length;M<z;M++){if(H.isInterleavedBufferAttribute)G=Y[M]*H.data.stride+H.offset;else G=Y[M]*U;for(let F=0;F<U;F++)N[D++]=X[G++]}return new wJ(N,U,E)}if(this.index===null)return C0("BufferGeometry.toNonIndexed(): BufferGeometry is already non-indexed."),this;let Q=new jJ,$=this.index.array,Z=this.attributes;for(let H in Z){let Y=Z[H],X=J(Y,$);Q.setAttribute(H,X)}let W=this.morphAttributes;for(let H in W){let Y=[],X=W[H];for(let U=0,E=X.length;U<E;U++){let N=X[U],G=J(N,$);Y.push(G)}Q.morphAttributes[H]=Y}Q.morphTargetsRelative=this.morphTargetsRelative;let K=this.groups;for(let H=0,Y=K.length;H<Y;H++){let X=K[H];Q.addGroup(X.start,X.count,X.materialIndex)}return Q}toJSON(){let J={metadata:{version:4.7,type:"BufferGeometry",generator:"BufferGeometry.toJSON"}};if(J.uuid=this.uuid,J.type=this.parameters!==void 0&&this._transformed===!0?"BufferGeometry":this.type,this.name!=="")J.name=this.name;if(Object.keys(this.userData).length>0)J.userData=this.userData;if(this.parameters!==void 0&&this._transformed!==!0){let Y=this.parameters;for(let X in Y)if(Y[X]!==void 0)J[X]=Y[X];return J}J.data={attributes:{}};let Q=this.index;if(Q!==null)J.data.index={type:Q.array.constructor.name,array:Array.prototype.slice.call(Q.array)};let $=this.attributes;for(let Y in $){let X=$[Y];J.data.attributes[Y]=X.toJSON(J.data)}let Z={},W=!1;for(let Y in this.morphAttributes){let X=this.morphAttributes[Y],U=[];for(let E=0,N=X.length;E<N;E++){let G=X[E];U.push(G.toJSON(J.data))}if(U.length>0)Z[Y]=U,W=!0}if(W)J.data.morphAttributes=Z,J.data.morphTargetsRelative=this.morphTargetsRelative;let K=this.groups;if(K.length>0)J.data.groups=JSON.parse(JSON.stringify(K));let H=this.boundingSphere;if(H!==null)J.data.boundingSphere=H.toJSON();return J}clone(){return new this.constructor().copy(this)}copy(J){this.index=null,this.attributes={},this.morphAttributes={},this.groups=[],this.boundingBox=null,this.boundingSphere=null;let Q={};this.name=J.name;let $=J.index;if($!==null)this.setIndex($.clone());let Z=J.attributes;for(let X in Z){let U=Z[X];this.setAttribute(X,U.clone(Q))}let W=J.morphAttributes;for(let X in W){let U=[],E=W[X];for(let N=0,G=E.length;N<G;N++)U.push(E[N].clone(Q));this.morphAttributes[X]=U}this.morphTargetsRelative=J.morphTargetsRelative;let K=J.groups;for(let X=0,U=K.length;X<U;X++){let E=K[X];this.addGroup(E.start,E.count,E.materialIndex)}let H=J.boundingBox;if(H!==null)this.boundingBox=H.clone();let Y=J.boundingSphere;if(Y!==null)this.boundingSphere=Y.clone();return this.drawRange.start=J.drawRange.start,this.drawRange.count=J.drawRange.count,this.userData=J.userData,this._transformed=J._transformed,this}dispose(){this.dispatchEvent({type:"dispose"})}}var eW=0;class l9 extends N9{constructor(){super();this.isMaterial=!0,Object.defineProperty(this,"id",{value:eW++}),this.uuid=S8(),this.name="",this.type="Material",this.blending=1,this.side=0,this.vertexColors=!1,this.opacity=1,this.transparent=!1,this.alphaHash=!1,this.blendSrc=204,this.blendDst=205,this.blendEquation=100,this.blendSrcAlpha=null,this.blendDstAlpha=null,this.blendEquationAlpha=null,this.blendColor=new g0(0,0,0),this.blendAlpha=0,this.depthFunc=3,this.depthTest=!0,this.depthWrite=!0,this.stencilWriteMask=255,this.stencilFunc=519,this.stencilRef=0,this.stencilFuncMask=255,this.stencilFail=7680,this.stencilZFail=7680,this.stencilZPass=7680,this.stencilWrite=!1,this.clippingPlanes=null,this.clipIntersection=!1,this.clipShadows=!1,this.shadowSide=null,this.colorWrite=!0,this.precision=null,this.polygonOffset=!1,this.polygonOffsetFactor=0,this.polygonOffsetUnits=0,this.dithering=!1,this.alphaToCoverage=!1,this.premultipliedAlpha=!1,this.forceSinglePass=!1,this.allowOverride=!0,this.visible=!0,this.toneMapped=!0,this.userData={},this.version=0,this._alphaTest=0}get alphaTest(){return this._alphaTest}set alphaTest(J){if(this._alphaTest>0!==J>0)this.version++;this._alphaTest=J}onBeforeRender(){}onBeforeCompile(){}customProgramCacheKey(){return this.onBeforeCompile.toString()}setValues(J){if(J===void 0)return;for(let Q in J){let $=J[Q];if($===void 0){C0(`Material: parameter '${Q}' has value of undefined.`);continue}let Z=this[Q];if(Z===void 0){C0(`Material: '${Q}' is not a property of THREE.${this.type}.`);continue}if(Z&&Z.isColor)Z.set($);else if(Z&&Z.isVector2&&($&&$.isVector2)||Z&&Z.isEuler&&($&&$.isEuler)||Z&&Z.isVector3&&($&&$.isVector3))Z.copy($);else this[Q]=$}}toJSON(J){let Q=J===void 0||typeof J==="string";if(Q)J={textures:{},images:{}};let $={metadata:{version:4.7,type:"Material",generator:"Material.toJSON"}};if($.uuid=this.uuid,$.type=this.type,this.name!=="")$.name=this.name;if(this.color&&this.color.isColor)$.color=this.color.getHex();if(this.roughness!==void 0)$.roughness=this.roughness;if(this.metalness!==void 0)$.metalness=this.metalness;if(this.sheen!==void 0)$.sheen=this.sheen;if(this.sheenColor&&this.sheenColor.isColor)$.sheenColor=this.sheenColor.getHex();if(this.sheenRoughness!==void 0)$.sheenRoughness=this.sheenRoughness;if(this.emissive&&this.emissive.isColor)$.emissive=this.emissive.getHex();if(this.emissiveIntensity!==void 0&&this.emissiveIntensity!==1)$.emissiveIntensity=this.emissiveIntensity;if(this.specular&&this.specular.isColor)$.specular=this.specular.getHex();if(this.specularIntensity!==void 0)$.specularIntensity=this.specularIntensity;if(this.specularColor&&this.specularColor.isColor)$.specularColor=this.specularColor.getHex();if(this.shininess!==void 0)$.shininess=this.shininess;if(this.clearcoat!==void 0)$.clearcoat=this.clearcoat;if(this.clearcoatRoughness!==void 0)$.clearcoatRoughness=this.clearcoatRoughness;if(this.clearcoatMap&&this.clearcoatMap.isTexture)$.clearcoatMap=this.clearcoatMap.toJSON(J).uuid;if(this.clearcoatRoughnessMap&&this.clearcoatRoughnessMap.isTexture)$.clearcoatRoughnessMap=this.clearcoatRoughnessMap.toJSON(J).uuid;if(this.clearcoatNormalMap&&this.clearcoatNormalMap.isTexture)$.clearcoatNormalMap=this.clearcoatNormalMap.toJSON(J).uuid,$.clearcoatNormalScale=this.clearcoatNormalScale.toArray();if(this.sheenColorMap&&this.sheenColorMap.isTexture)$.sheenColorMap=this.sheenColorMap.toJSON(J).uuid;if(this.sheenRoughnessMap&&this.sheenRoughnessMap.isTexture)$.sheenRoughnessMap=this.sheenRoughnessMap.toJSON(J).uuid;if(this.dispersion!==void 0)$.dispersion=this.dispersion;if(this.iridescence!==void 0)$.iridescence=this.iridescence;if(this.iridescenceIOR!==void 0)$.iridescenceIOR=this.iridescenceIOR;if(this.iridescenceThicknessRange!==void 0)$.iridescenceThicknessRange=this.iridescenceThicknessRange;if(this.iridescenceMap&&this.iridescenceMap.isTexture)$.iridescenceMap=this.iridescenceMap.toJSON(J).uuid;if(this.iridescenceThicknessMap&&this.iridescenceThicknessMap.isTexture)$.iridescenceThicknessMap=this.iridescenceThicknessMap.toJSON(J).uuid;if(this.anisotropy!==void 0)$.anisotropy=this.anisotropy;if(this.anisotropyRotation!==void 0)$.anisotropyRotation=this.anisotropyRotation;if(this.anisotropyMap&&this.anisotropyMap.isTexture)$.anisotropyMap=this.anisotropyMap.toJSON(J).uuid;if(this.map&&this.map.isTexture)$.map=this.map.toJSON(J).uuid;if(this.matcap&&this.matcap.isTexture)$.matcap=this.matcap.toJSON(J).uuid;if(this.alphaMap&&this.alphaMap.isTexture)$.alphaMap=this.alphaMap.toJSON(J).uuid;if(this.lightMap&&this.lightMap.isTexture)$.lightMap=this.lightMap.toJSON(J).uuid,$.lightMapIntensity=this.lightMapIntensity;if(this.aoMap&&this.aoMap.isTexture)$.aoMap=this.aoMap.toJSON(J).uuid,$.aoMapIntensity=this.aoMapIntensity;if(this.bumpMap&&this.bumpMap.isTexture)$.bumpMap=this.bumpMap.toJSON(J).uuid,$.bumpScale=this.bumpScale;if(this.normalMap&&this.normalMap.isTexture)$.normalMap=this.normalMap.toJSON(J).uuid,$.normalMapType=this.normalMapType,$.normalScale=this.normalScale.toArray();if(this.displacementMap&&this.displacementMap.isTexture)$.displacementMap=this.displacementMap.toJSON(J).uuid,$.displacementScale=this.displacementScale,$.displacementBias=this.displacementBias;if(this.roughnessMap&&this.roughnessMap.isTexture)$.roughnessMap=this.roughnessMap.toJSON(J).uuid;if(this.metalnessMap&&this.metalnessMap.isTexture)$.metalnessMap=this.metalnessMap.toJSON(J).uuid;if(this.emissiveMap&&this.emissiveMap.isTexture)$.emissiveMap=this.emissiveMap.toJSON(J).uuid;if(this.specularMap&&this.specularMap.isTexture)$.specularMap=this.specularMap.toJSON(J).uuid;if(this.specularIntensityMap&&this.specularIntensityMap.isTexture)$.specularIntensityMap=this.specularIntensityMap.toJSON(J).uuid;if(this.specularColorMap&&this.specularColorMap.isTexture)$.specularColorMap=this.specularColorMap.toJSON(J).uuid;if(this.envMap&&this.envMap.isTexture){if($.envMap=this.envMap.toJSON(J).uuid,this.combine!==void 0)$.combine=this.combine}if(this.envMapRotation!==void 0)$.envMapRotation=this.envMapRotation.toArray();if(this.envMapIntensity!==void 0)$.envMapIntensity=this.envMapIntensity;if(this.reflectivity!==void 0)$.reflectivity=this.reflectivity;if(this.refractionRatio!==void 0)$.refractionRatio=this.refractionRatio;if(this.gradientMap&&this.gradientMap.isTexture)$.gradientMap=this.gradientMap.toJSON(J).uuid;if(this.transmission!==void 0)$.transmission=this.transmission;if(this.transmissionMap&&this.transmissionMap.isTexture)$.transmissionMap=this.transmissionMap.toJSON(J).uuid;if(this.thickness!==void 0)$.thickness=this.thickness;if(this.thicknessMap&&this.thicknessMap.isTexture)$.thicknessMap=this.thicknessMap.toJSON(J).uuid;if(this.attenuationDistance!==void 0&&this.attenuationDistance!==1/0)$.attenuationDistance=this.attenuationDistance;if(this.attenuationColor!==void 0)$.attenuationColor=this.attenuationColor.getHex();if(this.size!==void 0)$.size=this.size;if(this.shadowSide!==null)$.shadowSide=this.shadowSide;if(this.sizeAttenuation!==void 0)$.sizeAttenuation=this.sizeAttenuation;if(this.blending!==1)$.blending=this.blending;if(this.side!==0)$.side=this.side;if(this.vertexColors===!0)$.vertexColors=!0;if(this.opacity<1)$.opacity=this.opacity;if(this.transparent===!0)$.transparent=!0;if(this.blendSrc!==204)$.blendSrc=this.blendSrc;if(this.blendDst!==205)$.blendDst=this.blendDst;if(this.blendEquation!==100)$.blendEquation=this.blendEquation;if(this.blendSrcAlpha!==null)$.blendSrcAlpha=this.blendSrcAlpha;if(this.blendDstAlpha!==null)$.blendDstAlpha=this.blendDstAlpha;if(this.blendEquationAlpha!==null)$.blendEquationAlpha=this.blendEquationAlpha;if(this.blendColor&&this.blendColor.isColor)$.blendColor=this.blendColor.getHex();if(this.blendAlpha!==0)$.blendAlpha=this.blendAlpha;if(this.depthFunc!==3)$.depthFunc=this.depthFunc;if(this.depthTest===!1)$.depthTest=this.depthTest;if(this.depthWrite===!1)$.depthWrite=this.depthWrite;if(this.colorWrite===!1)$.colorWrite=this.colorWrite;if(this.stencilWriteMask!==255)$.stencilWriteMask=this.stencilWriteMask;if(this.stencilFunc!==519)$.stencilFunc=this.stencilFunc;if(this.stencilRef!==0)$.stencilRef=this.stencilRef;if(this.stencilFuncMask!==255)$.stencilFuncMask=this.stencilFuncMask;if(this.stencilFail!==7680)$.stencilFail=this.stencilFail;if(this.stencilZFail!==7680)$.stencilZFail=this.stencilZFail;if(this.stencilZPass!==7680)$.stencilZPass=this.stencilZPass;if(this.stencilWrite===!0)$.stencilWrite=this.stencilWrite;if(this.rotation!==void 0&&this.rotation!==0)$.rotation=this.rotation;if(this.polygonOffset===!0)$.polygonOffset=!0;if(this.polygonOffsetFactor!==0)$.polygonOffsetFactor=this.polygonOffsetFactor;if(this.polygonOffsetUnits!==0)$.polygonOffsetUnits=this.polygonOffsetUnits;if(this.linewidth!==void 0&&this.linewidth!==1)$.linewidth=this.linewidth;if(this.dashSize!==void 0)$.dashSize=this.dashSize;if(this.gapSize!==void 0)$.gapSize=this.gapSize;if(this.scale!==void 0)$.scale=this.scale;if(this.dithering===!0)$.dithering=!0;if(this.alphaTest>0)$.alphaTest=this.alphaTest;if(this.alphaHash===!0)$.alphaHash=!0;if(this.alphaToCoverage===!0)$.alphaToCoverage=!0;if(this.premultipliedAlpha===!0)$.premultipliedAlpha=!0;if(this.forceSinglePass===!0)$.forceSinglePass=!0;if(this.allowOverride===!1)$.allowOverride=!1;if(this.wireframe===!0)$.wireframe=!0;if(this.wireframeLinewidth>1)$.wireframeLinewidth=this.wireframeLinewidth;if(this.wireframeLinecap!=="round")$.wireframeLinecap=this.wireframeLinecap;if(this.wireframeLinejoin!=="round")$.wireframeLinejoin=this.wireframeLinejoin;if(this.flatShading===!0)$.flatShading=!0;if(this.visible===!1)$.visible=!1;if(this.toneMapped===!1)$.toneMapped=!1;if(this.fog===!1)$.fog=!1;if(Object.keys(this.userData).length>0)$.userData=this.userData;function Z(W){let K=[];for(let H in W){let Y=W[H];delete Y.metadata,K.push(Y)}return K}if(Q){let W=Z(J.textures),K=Z(J.images);if(W.length>0)$.textures=W;if(K.length>0)$.images=K}return $}fromJSON(J,Q){if(J.uuid!==void 0)this.uuid=J.uuid;if(J.name!==void 0)this.name=J.name;if(J.color!==void 0&&this.color!==void 0)this.color.setHex(J.color);if(J.roughness!==void 0)this.roughness=J.roughness;if(J.metalness!==void 0)this.metalness=J.metalness;if(J.sheen!==void 0)this.sheen=J.sheen;if(J.sheenColor!==void 0)this.sheenColor=new g0().setHex(J.sheenColor);if(J.sheenRoughness!==void 0)this.sheenRoughness=J.sheenRoughness;if(J.emissive!==void 0&&this.emissive!==void 0)this.emissive.setHex(J.emissive);if(J.specular!==void 0&&this.specular!==void 0)this.specular.setHex(J.specular);if(J.specularIntensity!==void 0)this.specularIntensity=J.specularIntensity;if(J.specularColor!==void 0&&this.specularColor!==void 0)this.specularColor.setHex(J.specularColor);if(J.shininess!==void 0)this.shininess=J.shininess;if(J.clearcoat!==void 0)this.clearcoat=J.clearcoat;if(J.clearcoatRoughness!==void 0)this.clearcoatRoughness=J.clearcoatRoughness;if(J.dispersion!==void 0)this.dispersion=J.dispersion;if(J.iridescence!==void 0)this.iridescence=J.iridescence;if(J.iridescenceIOR!==void 0)this.iridescenceIOR=J.iridescenceIOR;if(J.iridescenceThicknessRange!==void 0)this.iridescenceThicknessRange=J.iridescenceThicknessRange;if(J.transmission!==void 0)this.transmission=J.transmission;if(J.thickness!==void 0)this.thickness=J.thickness;if(J.attenuationDistance!==void 0)this.attenuationDistance=J.attenuationDistance;if(J.attenuationColor!==void 0&&this.attenuationColor!==void 0)this.attenuationColor.setHex(J.attenuationColor);if(J.anisotropy!==void 0)this.anisotropy=J.anisotropy;if(J.anisotropyRotation!==void 0)this.anisotropyRotation=J.anisotropyRotation;if(J.fog!==void 0)this.fog=J.fog;if(J.flatShading!==void 0)this.flatShading=J.flatShading;if(J.blending!==void 0)this.blending=J.blending;if(J.combine!==void 0)this.combine=J.combine;if(J.side!==void 0)this.side=J.side;if(J.shadowSide!==void 0)this.shadowSide=J.shadowSide;if(J.opacity!==void 0)this.opacity=J.opacity;if(J.transparent!==void 0)this.transparent=J.transparent;if(J.alphaTest!==void 0)this.alphaTest=J.alphaTest;if(J.alphaHash!==void 0)this.alphaHash=J.alphaHash;if(J.depthFunc!==void 0)this.depthFunc=J.depthFunc;if(J.depthTest!==void 0)this.depthTest=J.depthTest;if(J.depthWrite!==void 0)this.depthWrite=J.depthWrite;if(J.colorWrite!==void 0)this.colorWrite=J.colorWrite;if(J.blendSrc!==void 0)this.blendSrc=J.blendSrc;if(J.blendDst!==void 0)this.blendDst=J.blendDst;if(J.blendEquation!==void 0)this.blendEquation=J.blendEquation;if(J.blendSrcAlpha!==void 0)this.blendSrcAlpha=J.blendSrcAlpha;if(J.blendDstAlpha!==void 0)this.blendDstAlpha=J.blendDstAlpha;if(J.blendEquationAlpha!==void 0)this.blendEquationAlpha=J.blendEquationAlpha;if(J.blendColor!==void 0&&this.blendColor!==void 0)this.blendColor.setHex(J.blendColor);if(J.blendAlpha!==void 0)this.blendAlpha=J.blendAlpha;if(J.stencilWriteMask!==void 0)this.stencilWriteMask=J.stencilWriteMask;if(J.stencilFunc!==void 0)this.stencilFunc=J.stencilFunc;if(J.stencilRef!==void 0)this.stencilRef=J.stencilRef;if(J.stencilFuncMask!==void 0)this.stencilFuncMask=J.stencilFuncMask;if(J.stencilFail!==void 0)this.stencilFail=J.stencilFail;if(J.stencilZFail!==void 0)this.stencilZFail=J.stencilZFail;if(J.stencilZPass!==void 0)this.stencilZPass=J.stencilZPass;if(J.stencilWrite!==void 0)this.stencilWrite=J.stencilWrite;if(J.wireframe!==void 0)this.wireframe=J.wireframe;if(J.wireframeLinewidth!==void 0)this.wireframeLinewidth=J.wireframeLinewidth;if(J.wireframeLinecap!==void 0)this.wireframeLinecap=J.wireframeLinecap;if(J.wireframeLinejoin!==void 0)this.wireframeLinejoin=J.wireframeLinejoin;if(J.rotation!==void 0)this.rotation=J.rotation;if(J.linewidth!==void 0)this.linewidth=J.linewidth;if(J.dashSize!==void 0)this.dashSize=J.dashSize;if(J.gapSize!==void 0)this.gapSize=J.gapSize;if(J.scale!==void 0)this.scale=J.scale;if(J.polygonOffset!==void 0)this.polygonOffset=J.polygonOffset;if(J.polygonOffsetFactor!==void 0)this.polygonOffsetFactor=J.polygonOffsetFactor;if(J.polygonOffsetUnits!==void 0)this.polygonOffsetUnits=J.polygonOffsetUnits;if(J.dithering!==void 0)this.dithering=J.dithering;if(J.alphaToCoverage!==void 0)this.alphaToCoverage=J.alphaToCoverage;if(J.premultipliedAlpha!==void 0)this.premultipliedAlpha=J.premultipliedAlpha;if(J.forceSinglePass!==void 0)this.forceSinglePass=J.forceSinglePass;if(J.allowOverride!==void 0)this.allowOverride=J.allowOverride;if(J.visible!==void 0)this.visible=J.visible;if(J.toneMapped!==void 0)this.toneMapped=J.toneMapped;if(J.userData!==void 0)this.userData=J.userData;if(J.vertexColors!==void 0)if(typeof J.vertexColors==="number")this.vertexColors=J.vertexColors>0;else this.vertexColors=J.vertexColors;if(J.size!==void 0)this.size=J.size;if(J.sizeAttenuation!==void 0)this.sizeAttenuation=J.sizeAttenuation;if(J.map!==void 0)this.map=Q[J.map]||null;if(J.matcap!==void 0)this.matcap=Q[J.matcap]||null;if(J.alphaMap!==void 0)this.alphaMap=Q[J.alphaMap]||null;if(J.bumpMap!==void 0)this.bumpMap=Q[J.bumpMap]||null;if(J.bumpScale!==void 0)this.bumpScale=J.bumpScale;if(J.normalMap!==void 0)this.normalMap=Q[J.normalMap]||null;if(J.normalMapType!==void 0)this.normalMapType=J.normalMapType;if(J.normalScale!==void 0){let $=J.normalScale;if(Array.isArray($)===!1)$=[$,$];this.normalScale=new u0().fromArray($)}if(J.displacementMap!==void 0)this.displacementMap=Q[J.displacementMap]||null;if(J.displacementScale!==void 0)this.displacementScale=J.displacementScale;if(J.displacementBias!==void 0)this.displacementBias=J.displacementBias;if(J.roughnessMap!==void 0)this.roughnessMap=Q[J.roughnessMap]||null;if(J.metalnessMap!==void 0)this.metalnessMap=Q[J.metalnessMap]||null;if(J.emissiveMap!==void 0)this.emissiveMap=Q[J.emissiveMap]||null;if(J.emissiveIntensity!==void 0)this.emissiveIntensity=J.emissiveIntensity;if(J.specularMap!==void 0)this.specularMap=Q[J.specularMap]||null;if(J.specularIntensityMap!==void 0)this.specularIntensityMap=Q[J.specularIntensityMap]||null;if(J.specularColorMap!==void 0)this.specularColorMap=Q[J.specularColorMap]||null;if(J.envMap!==void 0)this.envMap=Q[J.envMap]||null;if(J.envMapRotation!==void 0)this.envMapRotation.fromArray(J.envMapRotation);if(J.envMapIntensity!==void 0)this.envMapIntensity=J.envMapIntensity;if(J.reflectivity!==void 0)this.reflectivity=J.reflectivity;if(J.refractionRatio!==void 0)this.refractionRatio=J.refractionRatio;if(J.lightMap!==void 0)this.lightMap=Q[J.lightMap]||null;if(J.lightMapIntensity!==void 0)this.lightMapIntensity=J.lightMapIntensity;if(J.aoMap!==void 0)this.aoMap=Q[J.aoMap]||null;if(J.aoMapIntensity!==void 0)this.aoMapIntensity=J.aoMapIntensity;if(J.gradientMap!==void 0)this.gradientMap=Q[J.gradientMap]||null;if(J.clearcoatMap!==void 0)this.clearcoatMap=Q[J.clearcoatMap]||null;if(J.clearcoatRoughnessMap!==void 0)this.clearcoatRoughnessMap=Q[J.clearcoatRoughnessMap]||null;if(J.clearcoatNormalMap!==void 0)this.clearcoatNormalMap=Q[J.clearcoatNormalMap]||null;if(J.clearcoatNormalScale!==void 0)this.clearcoatNormalScale=new u0().fromArray(J.clearcoatNormalScale);if(J.iridescenceMap!==void 0)this.iridescenceMap=Q[J.iridescenceMap]||null;if(J.iridescenceThicknessMap!==void 0)this.iridescenceThicknessMap=Q[J.iridescenceThicknessMap]||null;if(J.transmissionMap!==void 0)this.transmissionMap=Q[J.transmissionMap]||null;if(J.thicknessMap!==void 0)this.thicknessMap=Q[J.thicknessMap]||null;if(J.anisotropyMap!==void 0)this.anisotropyMap=Q[J.anisotropyMap]||null;if(J.sheenColorMap!==void 0)this.sheenColorMap=Q[J.sheenColorMap]||null;if(J.sheenRoughnessMap!==void 0)this.sheenRoughnessMap=Q[J.sheenRoughnessMap]||null;return this}clone(){return new this.constructor().copy(this)}copy(J){this.name=J.name,this.blending=J.blending,this.side=J.side,this.vertexColors=J.vertexColors,this.opacity=J.opacity,this.transparent=J.transparent,this.blendSrc=J.blendSrc,this.blendDst=J.blendDst,this.blendEquation=J.blendEquation,this.blendSrcAlpha=J.blendSrcAlpha,this.blendDstAlpha=J.blendDstAlpha,this.blendEquationAlpha=J.blendEquationAlpha,this.blendColor.copy(J.blendColor),this.blendAlpha=J.blendAlpha,this.depthFunc=J.depthFunc,this.depthTest=J.depthTest,this.depthWrite=J.depthWrite,this.stencilWriteMask=J.stencilWriteMask,this.stencilFunc=J.stencilFunc,this.stencilRef=J.stencilRef,this.stencilFuncMask=J.stencilFuncMask,this.stencilFail=J.stencilFail,this.stencilZFail=J.stencilZFail,this.stencilZPass=J.stencilZPass,this.stencilWrite=J.stencilWrite;let Q=J.clippingPlanes,$=null;if(Q!==null){let Z=Q.length;$=Array(Z);for(let W=0;W!==Z;++W)$[W]=Q[W].clone()}return this.clippingPlanes=$,this.clipIntersection=J.clipIntersection,this.clipShadows=J.clipShadows,this.shadowSide=J.shadowSide,this.colorWrite=J.colorWrite,this.precision=J.precision,this.polygonOffset=J.polygonOffset,this.polygonOffsetFactor=J.polygonOffsetFactor,this.polygonOffsetUnits=J.polygonOffsetUnits,this.dithering=J.dithering,this.alphaTest=J.alphaTest,this.alphaHash=J.alphaHash,this.alphaToCoverage=J.alphaToCoverage,this.premultipliedAlpha=J.premultipliedAlpha,this.forceSinglePass=J.forceSinglePass,this.allowOverride=J.allowOverride,this.visible=J.visible,this.toneMapped=J.toneMapped,this.userData=JSON.parse(JSON.stringify(J.userData)),this}dispose(){this.dispatchEvent({type:"dispose"})}set needsUpdate(J){if(J===!0)this.version++}}var Y9=new b,U7=new b,o8=new b,B9=new b,G7=new b,a8=new b,E7=new b;class _6{constructor(J=new b,Q=new b(0,0,-1)){this.origin=J,this.direction=Q}set(J,Q){return this.origin.copy(J),this.direction.copy(Q),this}copy(J){return this.origin.copy(J.origin),this.direction.copy(J.direction),this}at(J,Q){return Q.copy(this.origin).addScaledVector(this.direction,J)}lookAt(J){return this.direction.copy(J).sub(this.origin).normalize(),this}recast(J){return this.origin.copy(this.at(J,Y9)),this}closestPointToPoint(J,Q){Q.subVectors(J,this.origin);let $=Q.dot(this.direction);if($<0)return Q.copy(this.origin);return Q.copy(this.origin).addScaledVector(this.direction,$)}distanceToPoint(J){return Math.sqrt(this.distanceSqToPoint(J))}distanceSqToPoint(J){let Q=Y9.subVectors(J,this.origin).dot(this.direction);if(Q<0)return this.origin.distanceToSquared(J);return Y9.copy(this.origin).addScaledVector(this.direction,Q),Y9.distanceToSquared(J)}distanceSqToSegment(J,Q,$,Z){U7.copy(J).add(Q).multiplyScalar(0.5),o8.copy(Q).sub(J).normalize(),B9.copy(this.origin).sub(U7);let W=J.distanceTo(Q)*0.5,K=-this.direction.dot(o8),H=B9.dot(this.direction),Y=-B9.dot(o8),X=B9.lengthSq(),U=Math.abs(1-K*K),E,N,G,D;if(U>0)if(E=K*Y-H,N=K*H-Y,D=W*U,E>=0)if(N>=-D)if(N<=D){let M=1/U;E*=M,N*=M,G=E*(E+K*N+2*H)+N*(K*E+N+2*Y)+X}else N=W,E=Math.max(0,-(K*N+H)),G=-E*E+N*(N+2*Y)+X;else N=-W,E=Math.max(0,-(K*N+H)),G=-E*E+N*(N+2*Y)+X;else if(N<=-D)E=Math.max(0,-(-K*W+H)),N=E>0?-W:Math.min(Math.max(-W,-Y),W),G=-E*E+N*(N+2*Y)+X;else if(N<=D)E=0,N=Math.min(Math.max(-W,-Y),W),G=N*(N+2*Y)+X;else E=Math.max(0,-(K*W+H)),N=E>0?W:Math.min(Math.max(-W,-Y),W),G=-E*E+N*(N+2*Y)+X;else N=K>0?-W:W,E=Math.max(0,-(K*N+H)),G=-E*E+N*(N+2*Y)+X;if($)$.copy(this.origin).addScaledVector(this.direction,E);if(Z)Z.copy(U7).addScaledVector(o8,N);return G}intersectSphere(J,Q){Y9.subVectors(J.center,this.origin);let $=Y9.dot(this.direction),Z=Y9.dot(Y9)-$*$,W=J.radius*J.radius;if(Z>W)return null;let K=Math.sqrt(W-Z),H=$-K,Y=$+K;if(Y<0)return null;if(H<0)return this.at(Y,Q);return this.at(H,Q)}intersectsSphere(J){if(J.radius<0)return!1;return this.distanceSqToPoint(J.center)<=J.radius*J.radius}distanceToPlane(J){let Q=J.normal.dot(this.direction);if(Q===0){if(J.distanceToPoint(this.origin)===0)return 0;return null}let $=-(this.origin.dot(J.normal)+J.constant)/Q;return $>=0?$:null}intersectPlane(J,Q){let $=this.distanceToPlane(J);if($===null)return null;return this.at($,Q)}intersectsPlane(J){let Q=J.distanceToPoint(this.origin);if(Q===0)return!0;if(J.normal.dot(this.direction)*Q<0)return!0;return!1}intersectBox(J,Q){let $,Z,W,K,H,Y,X=1/this.direction.x,U=1/this.direction.y,E=1/this.direction.z,N=this.origin;if(X>=0)$=(J.min.x-N.x)*X,Z=(J.max.x-N.x)*X;else $=(J.max.x-N.x)*X,Z=(J.min.x-N.x)*X;if(U>=0)W=(J.min.y-N.y)*U,K=(J.max.y-N.y)*U;else W=(J.max.y-N.y)*U,K=(J.min.y-N.y)*U;if($>K||W>Z)return null;if(W>$||isNaN($))$=W;if(K<Z||isNaN(Z))Z=K;if(E>=0)H=(J.min.z-N.z)*E,Y=(J.max.z-N.z)*E;else H=(J.max.z-N.z)*E,Y=(J.min.z-N.z)*E;if($>Y||H>Z)return null;if(H>$||$!==$)$=H;if(Y<Z||Z!==Z)Z=Y;if(Z<0)return null;return this.at($>=0?$:Z,Q)}intersectsBox(J){return this.intersectBox(J,Y9)!==null}intersectTriangle(J,Q,$,Z,W){G7.subVectors(Q,J),a8.subVectors($,J),E7.crossVectors(G7,a8);let K=this.direction.dot(E7),H;if(K>0){if(Z)return null;H=1}else if(K<0)H=-1,K=-K;else return null;B9.subVectors(this.origin,J);let Y=H*this.direction.dot(a8.crossVectors(B9,a8));if(Y<0)return null;let X=H*this.direction.dot(G7.cross(B9));if(X<0)return null;if(Y+X>K)return null;let U=-H*B9.dot(E7);if(U<0)return null;return this.at(U/K,W)}applyMatrix4(J){return this.origin.applyMatrix4(J),this.direction.transformDirection(J),this}equals(J){return J.origin.equals(this.origin)&&J.direction.equals(this.direction)}clone(){return new this.constructor().copy(this)}}class P6 extends l9{constructor(J){super();this.isMeshBasicMaterial=!0,this.type="MeshBasicMaterial",this.color=new g0(16777215),this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.specularMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new A9,this.combine=0,this.reflectivity=1,this.refractionRatio=0.98,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.fog=!0,this.setValues(J)}copy(J){return super.copy(J),this.color.copy(J.color),this.map=J.map,this.lightMap=J.lightMap,this.lightMapIntensity=J.lightMapIntensity,this.aoMap=J.aoMap,this.aoMapIntensity=J.aoMapIntensity,this.specularMap=J.specularMap,this.alphaMap=J.alphaMap,this.envMap=J.envMap,this.envMapRotation.copy(J.envMapRotation),this.combine=J.combine,this.reflectivity=J.reflectivity,this.refractionRatio=J.refractionRatio,this.wireframe=J.wireframe,this.wireframeLinewidth=J.wireframeLinewidth,this.wireframeLinecap=J.wireframeLinecap,this.wireframeLinejoin=J.wireframeLinejoin,this.fog=J.fog,this}}var A$=new WJ,y9=new _6,r8=new R8,w$=new b,t8=new b,e8=new b,J6=new b,N7=new b,Q6=new b,C$=new b,$6=new b;class sJ extends BJ{constructor(J=new jJ,Q=new P6){super();this.isMesh=!0,this.type="Mesh",this.geometry=J,this.material=Q,this.morphTargetDictionary=void 0,this.morphTargetInfluences=void 0,this.count=1,this.updateMorphTargets()}copy(J,Q){if(super.copy(J,Q),J.morphTargetInfluences!==void 0)this.morphTargetInfluences=J.morphTargetInfluences.slice();if(J.morphTargetDictionary!==void 0)this.morphTargetDictionary=Object.assign({},J.morphTargetDictionary);return this.material=Array.isArray(J.material)?J.material.slice():J.material,this.geometry=J.geometry,this}updateMorphTargets(){let Q=this.geometry.morphAttributes,$=Object.keys(Q);if($.length>0){let Z=Q[$[0]];if(Z!==void 0){this.morphTargetInfluences=[],this.morphTargetDictionary={};for(let W=0,K=Z.length;W<K;W++){let H=Z[W].name||String(W);this.morphTargetInfluences.push(0),this.morphTargetDictionary[H]=W}}}}getVertexPosition(J,Q){let $=this.geometry,Z=$.attributes.position,W=$.morphAttributes.position,K=$.morphTargetsRelative;Q.fromBufferAttribute(Z,J);let H=this.morphTargetInfluences;if(W&&H){Q6.set(0,0,0);for(let Y=0,X=W.length;Y<X;Y++){let U=H[Y],E=W[Y];if(U===0)continue;if(N7.fromBufferAttribute(E,J),K)Q6.addScaledVector(N7,U);else Q6.addScaledVector(N7.sub(Q),U)}Q.add(Q6)}return Q}raycast(J,Q){let $=this.geometry,Z=this.material,W=this.matrixWorld;if(Z===void 0)return;if($.boundingSphere===null)$.computeBoundingSphere();if(r8.copy($.boundingSphere),r8.applyMatrix4(W),y9.copy(J.ray).recast(J.near),r8.containsPoint(y9.origin)===!1){if(y9.intersectSphere(r8,w$)===null)return;if(y9.origin.distanceToSquared(w$)>(J.far-J.near)**2)return}if(A$.copy(W).invert(),y9.copy(J.ray).applyMatrix4(A$),$.boundingBox!==null){if(y9.intersectsBox($.boundingBox)===!1)return}this._computeIntersections(J,Q,y9)}_computeIntersections(J,Q,$){let Z,W=this.geometry,K=this.material,H=W.index,Y=W.attributes.position,X=W.attributes.uv,U=W.attributes.uv1,E=W.attributes.normal,N=W.groups,G=W.drawRange;if(H!==null)if(Array.isArray(K))for(let D=0,M=N.length;D<M;D++){let z=N[D],F=K[z.materialIndex],q=Math.max(z.start,G.start),_=Math.min(H.count,Math.min(z.start+z.count,G.start+G.count));for(let w=q,V=_;w<V;w+=3){let A=H.getX(w),I=H.getX(w+1),P=H.getX(w+2);if(Z=Z6(this,F,J,$,X,U,E,A,I,P),Z)Z.faceIndex=Math.floor(w/3),Z.face.materialIndex=z.materialIndex,Q.push(Z)}}else{let D=Math.max(0,G.start),M=Math.min(H.count,G.start+G.count);for(let z=D,F=M;z<F;z+=3){let q=H.getX(z),_=H.getX(z+1),w=H.getX(z+2);if(Z=Z6(this,K,J,$,X,U,E,q,_,w),Z)Z.faceIndex=Math.floor(z/3),Q.push(Z)}}else if(Y!==void 0)if(Array.isArray(K))for(let D=0,M=N.length;D<M;D++){let z=N[D],F=K[z.materialIndex],q=Math.max(z.start,G.start),_=Math.min(Y.count,Math.min(z.start+z.count,G.start+G.count));for(let w=q,V=_;w<V;w+=3){let A=w,I=w+1,P=w+2;if(Z=Z6(this,F,J,$,X,U,E,A,I,P),Z)Z.faceIndex=Math.floor(w/3),Z.face.materialIndex=z.materialIndex,Q.push(Z)}}else{let D=Math.max(0,G.start),M=Math.min(Y.count,G.start+G.count);for(let z=D,F=M;z<F;z+=3){let q=z,_=z+1,w=z+2;if(Z=Z6(this,K,J,$,X,U,E,q,_,w),Z)Z.faceIndex=Math.floor(z/3),Q.push(Z)}}}}function JK(J,Q,$,Z,W,K,H,Y){let X;if(Q.side===1)X=Z.intersectTriangle(H,K,W,!0,Y);else X=Z.intersectTriangle(W,K,H,Q.side===0,Y);if(X===null)return null;$6.copy(Y),$6.applyMatrix4(J.matrixWorld);let U=$.ray.origin.distanceTo($6);if(U<$.near||U>$.far)return null;return{distance:U,point:$6.clone(),object:J}}function Z6(J,Q,$,Z,W,K,H,Y,X,U){J.getVertexPosition(Y,t8),J.getVertexPosition(X,e8),J.getVertexPosition(U,J6);let E=JK(J,Q,$,Z,t8,e8,J6,C$);if(E){let N=new b;if(hJ.getBarycoord(C$,t8,e8,J6,N),W)E.uv=hJ.getInterpolatedAttribute(W,Y,X,U,N,new u0);if(K)E.uv1=hJ.getInterpolatedAttribute(K,Y,X,U,N,new u0);if(H){if(E.normal=hJ.getInterpolatedAttribute(H,Y,X,U,N,new b),E.normal.dot(Z.direction)>0)E.normal.multiplyScalar(-1)}let G={a:Y,b:X,c:U,normal:new b,materialIndex:0};hJ.getNormal(t8,e8,J6,G.normal),E.face=G,E.barycoord=N}return E}class kQ extends VJ{constructor(J=null,Q=1,$=1,Z,W,K,H,Y,X=1003,U=1003,E,N){super(null,K,H,Y,X,U,Z,W,E,N);this.isDataTexture=!0,this.image={data:J,width:Q,height:$},this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}}var q7=new b,QK=new b,$K=new P0;class X9{constructor(J=new b(1,0,0),Q=0){this.isPlane=!0,this.normal=J,this.constant=Q}set(J,Q){return this.normal.copy(J),this.constant=Q,this}setComponents(J,Q,$,Z){return this.normal.set(J,Q,$),this.constant=Z,this}setFromNormalAndCoplanarPoint(J,Q){return this.normal.copy(J),this.constant=-Q.dot(this.normal),this}setFromCoplanarPoints(J,Q,$){let Z=q7.subVectors($,Q).cross(QK.subVectors(J,Q)).normalize();return this.setFromNormalAndCoplanarPoint(Z,J),this}copy(J){return this.normal.copy(J.normal),this.constant=J.constant,this}normalize(){let J=1/this.normal.length();return this.normal.multiplyScalar(J),this.constant*=J,this}negate(){return this.constant*=-1,this.normal.negate(),this}distanceToPoint(J){return this.normal.dot(J)+this.constant}distanceToSphere(J){return this.distanceToPoint(J.center)-J.radius}projectPoint(J,Q){return Q.copy(J).addScaledVector(this.normal,-this.distanceToPoint(J))}intersectLine(J,Q,$=!0){let Z=J.delta(q7),W=this.normal.dot(Z);if(W===0){if(this.distanceToPoint(J.start)===0)return Q.copy(J.start);return null}let K=-(J.start.dot(this.normal)+this.constant)/W;if($===!0&&(K<0||K>1))return null;return Q.copy(J.start).addScaledVector(Z,K)}intersectsLine(J){let Q=this.distanceToPoint(J.start),$=this.distanceToPoint(J.end);return Q<0&&$>0||$<0&&Q>0}intersectsBox(J){return J.intersectsPlane(this)}intersectsSphere(J){return J.intersectsPlane(this)}coplanarPoint(J){return J.copy(this.normal).multiplyScalar(-this.constant)}applyMatrix4(J,Q){let $=Q||$K.getNormalMatrix(J),Z=this.coplanarPoint(q7).applyMatrix4(J),W=this.normal.applyMatrix3($).normalize();return this.constant=-Z.dot(W),this}translate(J){return this.constant-=J.dot(this.normal),this}equals(J){return J.normal.equals(this.normal)&&J.constant===this.constant}clone(){return new this.constructor().copy(this)}}var f9=new R8,ZK=new u0(0.5,0.5),W6=new b;class T6{constructor(J=new X9,Q=new X9,$=new X9,Z=new X9,W=new X9,K=new X9){this.planes=[J,Q,$,Z,W,K]}set(J,Q,$,Z,W,K){let H=this.planes;return H[0].copy(J),H[1].copy(Q),H[2].copy($),H[3].copy(Z),H[4].copy(W),H[5].copy(K),this}copy(J){let Q=this.planes;for(let $=0;$<6;$++)Q[$].copy(J.planes[$]);return this}setFromProjectionMatrix(J,Q=2000,$=!1){let Z=this.planes,W=J.elements,K=W[0],H=W[1],Y=W[2],X=W[3],U=W[4],E=W[5],N=W[6],G=W[7],D=W[8],M=W[9],z=W[10],F=W[11],q=W[12],_=W[13],w=W[14],V=W[15];if(Z[0].setComponents(X-K,G-U,F-D,V-q).normalize(),Z[1].setComponents(X+K,G+U,F+D,V+q).normalize(),Z[2].setComponents(X+H,G+E,F+M,V+_).normalize(),Z[3].setComponents(X-H,G-E,F-M,V-_).normalize(),$)Z[4].setComponents(Y,N,z,w).normalize(),Z[5].setComponents(X-Y,G-N,F-z,V-w).normalize();else if(Z[4].setComponents(X-Y,G-N,F-z,V-w).normalize(),Q===2000)Z[5].setComponents(X+Y,G+N,F+z,V+w).normalize();else if(Q===2001)Z[5].setComponents(Y,N,z,w).normalize();else throw Error("THREE.Frustum.setFromProjectionMatrix(): Invalid coordinate system: "+Q);return this}intersectsObject(J){if(J.boundingSphere!==void 0){if(J.boundingSphere===null)J.computeBoundingSphere();f9.copy(J.boundingSphere).applyMatrix4(J.matrixWorld)}else{let Q=J.geometry;if(Q.boundingSphere===null)Q.computeBoundingSphere();f9.copy(Q.boundingSphere).applyMatrix4(J.matrixWorld)}return this.intersectsSphere(f9)}intersectsSprite(J){f9.center.set(0,0,0);let Q=ZK.distanceTo(J.center);return f9.radius=0.7071067811865476+Q,f9.applyMatrix4(J.matrixWorld),this.intersectsSphere(f9)}intersectsSphere(J){let Q=this.planes,$=J.center,Z=-J.radius;for(let W=0;W<6;W++)if(Q[W].distanceToPoint($)<Z)return!1;return!0}intersectsBox(J){let Q=this.planes;for(let $=0;$<6;$++){let Z=Q[$];if(W6.x=Z.normal.x>0?J.max.x:J.min.x,W6.y=Z.normal.y>0?J.max.y:J.min.y,W6.z=Z.normal.z>0?J.max.z:J.min.z,Z.distanceToPoint(W6)<0)return!1}return!0}containsPoint(J){let Q=this.planes;for(let $=0;$<6;$++)if(Q[$].distanceToPoint(J)<0)return!1;return!0}clone(){return new this.constructor().copy(this)}}class f8 extends l9{constructor(J){super();this.isPointsMaterial=!0,this.type="PointsMaterial",this.color=new g0(16777215),this.map=null,this.alphaMap=null,this.size=1,this.sizeAttenuation=!0,this.fog=!0,this.setValues(J)}copy(J){return super.copy(J),this.color.copy(J.color),this.map=J.map,this.alphaMap=J.alphaMap,this.size=J.size,this.sizeAttenuation=J.sizeAttenuation,this.fog=J.fog,this}}var _$=new WJ,F7=new _6,K6=new R8,H6=new b;class S6 extends BJ{constructor(J=new jJ,Q=new f8){super();this.isPoints=!0,this.type="Points",this.geometry=J,this.material=Q,this.morphTargetDictionary=void 0,this.morphTargetInfluences=void 0,this.updateMorphTargets()}copy(J,Q){return super.copy(J,Q),this.material=Array.isArray(J.material)?J.material.slice():J.material,this.geometry=J.geometry,this}raycast(J,Q){let $=this.geometry,Z=this.matrixWorld,W=J.params.Points.threshold,K=$.drawRange;if($.boundingSphere===null)$.computeBoundingSphere();if(K6.copy($.boundingSphere),K6.applyMatrix4(Z),K6.radius+=W,J.ray.intersectsSphere(K6)===!1)return;_$.copy(Z).invert(),F7.copy(J.ray).applyMatrix4(_$);let H=W/((this.scale.x+this.scale.y+this.scale.z)/3),Y=H*H,X=$.index,E=$.attributes.position;if(X!==null){let N=Math.max(0,K.start),G=Math.min(X.count,K.start+K.count);for(let D=N,M=G;D<M;D++){let z=X.getX(D);H6.fromBufferAttribute(E,z),P$(H6,z,Y,Z,J,Q,this)}}else{let N=Math.max(0,K.start),G=Math.min(E.count,K.start+K.count);for(let D=N,M=G;D<M;D++)H6.fromBufferAttribute(E,D),P$(H6,D,Y,Z,J,Q,this)}}updateMorphTargets(){let Q=this.geometry.morphAttributes,$=Object.keys(Q);if($.length>0){let Z=Q[$[0]];if(Z!==void 0){this.morphTargetInfluences=[],this.morphTargetDictionary={};for(let W=0,K=Z.length;W<K;W++){let H=Z[W].name||String(W);this.morphTargetInfluences.push(0),this.morphTargetDictionary[H]=W}}}}}function P$(J,Q,$,Z,W,K,H){let Y=F7.distanceSqToPoint(J);if(Y<$){let X=new b;F7.closestPointToPoint(J,X),X.applyMatrix4(Z);let U=W.ray.origin.distanceTo(X);if(U<W.near||U>W.far)return;K.push({distance:U,distanceToRay:Math.sqrt(Y),point:X,index:Q,face:null,faceIndex:null,barycoord:null,object:H})}}class j6 extends VJ{constructor(J=[],Q=301,$,Z,W,K,H,Y,X,U){super(J,Q,$,Z,W,K,H,Y,X,U);this.isCubeTexture=!0,this.flipY=!1}get images(){return this.image}set images(J){this.image=J}}class _9 extends VJ{constructor(J,Q,$=1014,Z,W,K,H=1003,Y=1003,X,U=1026,E=1){if(U!==1026&&U!==1027)throw Error("THREE.DepthTexture: format must be either THREE.DepthFormat or THREE.DepthStencilFormat");let N={width:J,height:Q,depth:E};super(N,Z,W,K,H,Y,U,$,X);this.isDepthTexture=!0,this.flipY=!1,this.generateMipmaps=!1,this.compareFunction=null}copy(J){return super.copy(J),this.source=new j8(Object.assign({},J.image)),this.compareFunction=J.compareFunction,this}toJSON(J){let Q=super.toJSON(J);if(this.compareFunction!==null)Q.compareFunction=this.compareFunction;return Q}}class MQ extends _9{constructor(J,Q=1014,$=301,Z,W,K=1003,H=1003,Y,X=1026){let U={width:J,height:J,depth:1},E=[U,U,U,U,U,U];super(J,J,Q,$,Z,W,K,H,Y,X);this.image=E,this.isCubeDepthTexture=!0,this.isCubeTexture=!0}get images(){return this.image}set images(J){this.image=J}}class y6 extends VJ{constructor(J=null){super();this.sourceTexture=J,this.isExternalTexture=!0}copy(J){return super.copy(J),this.sourceTexture=J.sourceTexture,this}}class O8 extends jJ{constructor(J=1,Q=1,$=1,Z=1,W=1,K=1){super();this.type="BoxGeometry",this.parameters={width:J,height:Q,depth:$,widthSegments:Z,heightSegments:W,depthSegments:K};let H=this;Z=Math.floor(Z),W=Math.floor(W),K=Math.floor(K);let Y=[],X=[],U=[],E=[],N=0,G=0;D("z","y","x",-1,-1,$,Q,J,K,W,0),D("z","y","x",1,-1,$,Q,-J,K,W,1),D("x","z","y",1,1,J,$,Q,Z,K,2),D("x","z","y",1,-1,J,$,-Q,Z,K,3),D("x","y","z",1,-1,J,Q,$,Z,W,4),D("x","y","z",-1,-1,J,Q,-$,Z,W,5),this.setIndex(Y),this.setAttribute("position",new uJ(X,3)),this.setAttribute("normal",new uJ(U,3)),this.setAttribute("uv",new uJ(E,2));function D(M,z,F,q,_,w,V,A,I,P,O){let B=w/I,l=V/P,C=w/2,m=V/2,o=A/2,p=I+1,n=P+1,u=0,h=0,t=new b;for(let e=0;e<n;e++){let H0=e*l-m;for(let M0=0;M0<p;M0++){let k0=M0*B-C;t[M]=k0*q,t[z]=H0*_,t[F]=o,X.push(t.x,t.y,t.z),t[M]=0,t[z]=0,t[F]=A>0?1:-1,U.push(t.x,t.y,t.z),E.push(M0/I),E.push(1-e/P),u+=1}}for(let e=0;e<P;e++)for(let H0=0;H0<I;H0++){let M0=N+H0+p*e,k0=N+H0+p*(e+1),ZJ=N+(H0+1)+p*(e+1),i0=N+(H0+1)+p*e;Y.push(M0,k0,i0),Y.push(k0,ZJ,i0),h+=6}H.addGroup(G,h,O),G+=h,N+=u}}copy(J){return super.copy(J),this.parameters=Object.assign({},J.parameters),this}static fromJSON(J){return new O8(J.width,J.height,J.depth,J.widthSegments,J.heightSegments,J.depthSegments)}}class v8 extends jJ{constructor(J=1,Q=1,$=1,Z=1){super();this.type="PlaneGeometry",this.parameters={width:J,height:Q,widthSegments:$,heightSegments:Z};let W=J/2,K=Q/2,H=Math.floor($),Y=Math.floor(Z),X=H+1,U=Y+1,E=J/H,N=Q/Y,G=[],D=[],M=[],z=[];for(let F=0;F<U;F++){let q=F*N-K;for(let _=0;_<X;_++){let w=_*E-W;D.push(w,-q,0),M.push(0,0,1),z.push(_/H),z.push(1-F/Y)}}for(let F=0;F<Y;F++)for(let q=0;q<H;q++){let _=q+X*F,w=q+X*(F+1),V=q+1+X*(F+1),A=q+1+X*F;G.push(_,w,A),G.push(w,V,A)}this.setIndex(G),this.setAttribute("position",new uJ(D,3)),this.setAttribute("normal",new uJ(M,3)),this.setAttribute("uv",new uJ(z,2))}copy(J){return super.copy(J),this.parameters=Object.assign({},J.parameters),this}static fromJSON(J){return new v8(J.width,J.height,J.widthSegments,J.heightSegments)}}function u9(J){let Q={};for(let $ in J){Q[$]={};for(let Z in J[$]){let W=J[$][Z];if(T$(W))if(W.isRenderTargetTexture)C0("UniformsUtils: Textures of render targets cannot be cloned via cloneUniforms() or mergeUniforms()."),Q[$][Z]=null;else Q[$][Z]=W.clone();else if(Array.isArray(W))if(T$(W[0])){let K=[];for(let H=0,Y=W.length;H<Y;H++)K[H]=W[H].clone();Q[$][Z]=K}else Q[$][Z]=W.slice();else Q[$][Z]=W}}return Q}function zJ(J){let Q={};for(let $=0;$<J.length;$++){let Z=u9(J[$]);for(let W in Z)Q[W]=Z[W]}return Q}function T$(J){return J&&(J.isColor||J.isMatrix3||J.isMatrix4||J.isVector2||J.isVector3||J.isVector4||J.isTexture||J.isQuaternion)}function WK(J){let Q=[];for(let $=0;$<J.length;$++)Q.push(J[$].clone());return Q}function LQ(J){let Q=J.getRenderTarget();if(Q===null)return J.outputColorSpace;if(Q.isXRRenderTarget===!0)return Q.texture.colorSpace;return h0.workingColorSpace}var bZ={clone:u9,merge:zJ},KK=`void main() {
	gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );
}`,HK=`void main() {
	gl_FragColor = vec4( 1.0, 0.0, 0.0, 1.0 );
}`;class gJ extends l9{constructor(J){super();if(this.isShaderMaterial=!0,this.type="ShaderMaterial",this.defines={},this.uniforms={},this.uniformsGroups=[],this.vertexShader=KK,this.fragmentShader=HK,this.linewidth=1,this.wireframe=!1,this.wireframeLinewidth=1,this.fog=!1,this.lights=!1,this.clipping=!1,this.forceSinglePass=!0,this.extensions={clipCullDistance:!1,multiDraw:!1},this.defaultAttributeValues={color:[1,1,1],uv:[0,0],uv1:[0,0]},this.index0AttributeName=void 0,this.uniformsNeedUpdate=!1,this.glslVersion=null,J!==void 0)this.setValues(J)}copy(J){return super.copy(J),this.fragmentShader=J.fragmentShader,this.vertexShader=J.vertexShader,this.uniforms=u9(J.uniforms),this.uniformsGroups=WK(J.uniformsGroups),this.defines=Object.assign({},J.defines),this.wireframe=J.wireframe,this.wireframeLinewidth=J.wireframeLinewidth,this.fog=J.fog,this.lights=J.lights,this.clipping=J.clipping,this.extensions=Object.assign({},J.extensions),this.glslVersion=J.glslVersion,this.defaultAttributeValues=Object.assign({},J.defaultAttributeValues),this.index0AttributeName=J.index0AttributeName,this.uniformsNeedUpdate=J.uniformsNeedUpdate,this}toJSON(J){let Q=super.toJSON(J);Q.glslVersion=this.glslVersion,Q.uniforms={};for(let Z in this.uniforms){let K=this.uniforms[Z].value;if(K&&K.isTexture)Q.uniforms[Z]={type:"t",value:K.toJSON(J).uuid};else if(K&&K.isColor)Q.uniforms[Z]={type:"c",value:K.getHex()};else if(K&&K.isVector2)Q.uniforms[Z]={type:"v2",value:K.toArray()};else if(K&&K.isVector3)Q.uniforms[Z]={type:"v3",value:K.toArray()};else if(K&&K.isVector4)Q.uniforms[Z]={type:"v4",value:K.toArray()};else if(K&&K.isMatrix3)Q.uniforms[Z]={type:"m3",value:K.toArray()};else if(K&&K.isMatrix4)Q.uniforms[Z]={type:"m4",value:K.toArray()};else Q.uniforms[Z]={value:K}}if(Object.keys(this.defines).length>0)Q.defines=this.defines;Q.vertexShader=this.vertexShader,Q.fragmentShader=this.fragmentShader,Q.lights=this.lights,Q.clipping=this.clipping;let $={};for(let Z in this.extensions)if(this.extensions[Z]===!0)$[Z]=!0;if(Object.keys($).length>0)Q.extensions=$;return Q}fromJSON(J,Q){if(super.fromJSON(J,Q),J.uniforms!==void 0)for(let $ in J.uniforms){let Z=J.uniforms[$];switch(this.uniforms[$]={},Z.type){case"t":this.uniforms[$].value=Q[Z.value]||null;break;case"c":this.uniforms[$].value=new g0().setHex(Z.value);break;case"v2":this.uniforms[$].value=new u0().fromArray(Z.value);break;case"v3":this.uniforms[$].value=new b().fromArray(Z.value);break;case"v4":this.uniforms[$].value=new KJ().fromArray(Z.value);break;case"m3":this.uniforms[$].value=new P0().fromArray(Z.value);break;case"m4":this.uniforms[$].value=new WJ().fromArray(Z.value);break;default:this.uniforms[$].value=Z.value}}if(J.defines!==void 0)this.defines=J.defines;if(J.vertexShader!==void 0)this.vertexShader=J.vertexShader;if(J.fragmentShader!==void 0)this.fragmentShader=J.fragmentShader;if(J.glslVersion!==void 0)this.glslVersion=J.glslVersion;if(J.extensions!==void 0)for(let $ in J.extensions)this.extensions[$]=J.extensions[$];if(J.lights!==void 0)this.lights=J.lights;if(J.clipping!==void 0)this.clipping=J.clipping;return this}}class VQ extends gJ{constructor(J){super(J);this.isRawShaderMaterial=!0,this.type="RawShaderMaterial"}}class BQ extends l9{constructor(J){super();this.isMeshDepthMaterial=!0,this.type="MeshDepthMaterial",this.depthPacking=3200,this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.wireframe=!1,this.wireframeLinewidth=1,this.setValues(J)}copy(J){return super.copy(J),this.depthPacking=J.depthPacking,this.map=J.map,this.alphaMap=J.alphaMap,this.displacementMap=J.displacementMap,this.displacementScale=J.displacementScale,this.displacementBias=J.displacementBias,this.wireframe=J.wireframe,this.wireframeLinewidth=J.wireframeLinewidth,this}}class zQ extends l9{constructor(J){super();this.isMeshDistanceMaterial=!0,this.type="MeshDistanceMaterial",this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.setValues(J)}copy(J){return super.copy(J),this.map=J.map,this.alphaMap=J.alphaMap,this.displacementMap=J.displacementMap,this.displacementScale=J.displacementScale,this.displacementBias=J.displacementBias,this}}function Y6(J,Q){if(!J||J.constructor===Q)return J;if(typeof Q.BYTES_PER_ELEMENT==="number")return new Q(J);return Array.prototype.slice.call(J)}class c9{constructor(J,Q,$,Z){this.parameterPositions=J,this._cachedIndex=0,this.resultBuffer=Z!==void 0?Z:new Q.constructor($),this.sampleValues=Q,this.valueSize=$,this.settings=null,this.DefaultSettings_={}}evaluate(J){let Q=this.parameterPositions,$=this._cachedIndex,Z=Q[$],W=Q[$-1];$:{J:{let K;Q:{Z:if(!(J<Z)){for(let H=$+2;;){if(Z===void 0){if(J<W)break Z;return $=Q.length,this._cachedIndex=$,this.copySampleValue_($-1)}if($===H)break;if(W=Z,Z=Q[++$],J<Z)break J}K=Q.length;break Q}if(!(J>=W)){let H=Q[1];if(J<H)$=2,W=H;for(let Y=$-2;;){if(W===void 0)return this._cachedIndex=0,this.copySampleValue_(0);if($===Y)break;if(Z=W,W=Q[--$-1],J>=W)break J}K=$,$=0;break Q}break $}while($<K){let H=$+K>>>1;if(J<Q[H])K=H;else $=H+1}if(Z=Q[$],W=Q[$-1],W===void 0)return this._cachedIndex=0,this.copySampleValue_(0);if(Z===void 0)return $=Q.length,this._cachedIndex=$,this.copySampleValue_($-1)}this._cachedIndex=$,this.intervalChanged_($,W,Z)}return this.interpolate_($,W,J,Z)}getSettings_(){return this.settings||this.DefaultSettings_}copySampleValue_(J){let Q=this.resultBuffer,$=this.sampleValues,Z=this.valueSize,W=J*Z;for(let K=0;K!==Z;++K)Q[K]=$[W+K];return Q}interpolate_(){throw Error("THREE.Interpolant: Call to abstract method.")}intervalChanged_(){}}class IQ extends c9{constructor(J,Q,$,Z){super(J,Q,$,Z);this._weightPrev=-0,this._offsetPrev=-0,this._weightNext=-0,this._offsetNext=-0,this.DefaultSettings_={endingStart:2400,endingEnd:2400}}intervalChanged_(J,Q,$){let Z=this.parameterPositions,W=J-2,K=J+1,H=Z[W],Y=Z[K];if(H===void 0)switch(this.getSettings_().endingStart){case 2401:W=J,H=2*Q-$;break;case 2402:W=Z.length-2,H=Q+Z[W]-Z[W+1];break;default:W=J,H=$}if(Y===void 0)switch(this.getSettings_().endingEnd){case 2401:K=J,Y=2*$-Q;break;case 2402:K=1,Y=$+Z[1]-Z[0];break;default:K=J-1,Y=Q}let X=($-Q)*0.5,U=this.valueSize;this._weightPrev=X/(Q-H),this._weightNext=X/(Y-$),this._offsetPrev=W*U,this._offsetNext=K*U}interpolate_(J,Q,$,Z){let W=this.resultBuffer,K=this.sampleValues,H=this.valueSize,Y=J*H,X=Y-H,U=this._offsetPrev,E=this._offsetNext,N=this._weightPrev,G=this._weightNext,D=($-Q)/(Z-Q),M=D*D,z=M*D,F=-N*z+2*N*M-N*D,q=(1+N)*z+(-1.5-2*N)*M+(-0.5+N)*D+1,_=(-1-G)*z+(1.5+G)*M+0.5*D,w=G*z-G*M;for(let V=0;V!==H;++V)W[V]=F*K[U+V]+q*K[X+V]+_*K[Y+V]+w*K[E+V];return W}}class AQ extends c9{constructor(J,Q,$,Z){super(J,Q,$,Z)}interpolate_(J,Q,$,Z){let W=this.resultBuffer,K=this.sampleValues,H=this.valueSize,Y=J*H,X=Y-H,U=($-Q)/(Z-Q),E=1-U;for(let N=0;N!==H;++N)W[N]=K[X+N]*E+K[Y+N]*U;return W}}class wQ extends c9{constructor(J,Q,$,Z){super(J,Q,$,Z)}interpolate_(J){return this.copySampleValue_(J-1)}}class CQ extends c9{interpolate_(J,Q,$,Z){let W=this.resultBuffer,K=this.sampleValues,H=this.valueSize,Y=J*H,X=Y-H,U=this.inTangents,E=this.outTangents;if(!U||!E){let D=($-Q)/(Z-Q),M=1-D;for(let z=0;z!==H;++z)W[z]=K[X+z]*M+K[Y+z]*D;return W}let N=H*2,G=J-1;for(let D=0;D!==H;++D){let M=K[X+D],z=K[Y+D],F=G*N+D*2,q=E[F],_=E[F+1],w=J*N+D*2,V=U[w],A=U[w+1],I=($-Q)/(Z-Q),P,O,B,l,C;for(let m=0;m<8;m++){P=I*I,O=P*I,B=1-I,l=B*B,C=l*B;let p=C*Q+3*l*I*q+3*B*P*V+O*Z-$;if(Math.abs(p)<0.0000000001)break;let n=3*l*(q-Q)+6*B*I*(V-q)+3*P*(Z-V);if(Math.abs(n)<0.0000000001)break;I=I-p/n,I=Math.max(0,Math.min(1,I))}W[D]=C*M+3*l*I*_+3*B*P*A+O*z}return W}}class pJ{constructor(J,Q,$,Z){if(J===void 0)throw Error("THREE.KeyframeTrack: track name is undefined");if(Q===void 0||Q.length===0)throw Error("THREE.KeyframeTrack: no keyframes in track named "+J);this.name=J,this.times=Y6(Q,this.TimeBufferType),this.values=Y6($,this.ValueBufferType),this.setInterpolation(Z||this.DefaultInterpolation)}static toJSON(J){let Q=J.constructor,$;if(Q.toJSON!==this.toJSON)$=Q.toJSON(J);else{$={name:J.name,times:Y6(J.times,Array),values:Y6(J.values,Array)};let Z=J.getInterpolation();if(Z!==J.DefaultInterpolation)$.interpolation=Z}return $.type=J.ValueTypeName,$}InterpolantFactoryMethodDiscrete(J){return new wQ(this.times,this.values,this.getValueSize(),J)}InterpolantFactoryMethodLinear(J){return new AQ(this.times,this.values,this.getValueSize(),J)}InterpolantFactoryMethodSmooth(J){return new IQ(this.times,this.values,this.getValueSize(),J)}InterpolantFactoryMethodBezier(J){let Q=new CQ(this.times,this.values,this.getValueSize(),J);if(this.settings)Q.inTangents=this.settings.inTangents,Q.outTangents=this.settings.outTangents;return Q}setInterpolation(J){let Q;switch(J){case 2300:Q=this.InterpolantFactoryMethodDiscrete;break;case 2301:Q=this.InterpolantFactoryMethodLinear;break;case 2302:Q=this.InterpolantFactoryMethodSmooth;break;case 2303:Q=this.InterpolantFactoryMethodBezier;break}if(Q===void 0){let $="unsupported interpolation for "+this.ValueTypeName+" keyframe track named "+this.name;if(this.createInterpolant===void 0)if(J!==this.DefaultInterpolation)this.setInterpolation(this.DefaultInterpolation);else throw Error($);return C0("KeyframeTrack:",$),this}return this.createInterpolant=Q,this}getInterpolation(){switch(this.createInterpolant){case this.InterpolantFactoryMethodDiscrete:return 2300;case this.InterpolantFactoryMethodLinear:return 2301;case this.InterpolantFactoryMethodSmooth:return 2302;case this.InterpolantFactoryMethodBezier:return 2303}}getValueSize(){return this.values.length/this.times.length}shift(J){if(J!==0){let Q=this.times;for(let $=0,Z=Q.length;$!==Z;++$)Q[$]+=J}return this}scale(J){if(J!==1){let Q=this.times;for(let $=0,Z=Q.length;$!==Z;++$)Q[$]*=J}return this}trim(J,Q){let $=this.times,Z=$.length,W=0,K=Z-1;while(W!==Z&&$[W]<J)++W;while(K!==-1&&$[K]>Q)--K;if(++K,W!==0||K!==Z){if(W>=K)K=Math.max(K,1),W=K-1;let H=this.getValueSize();this.times=$.slice(W,K),this.values=this.values.slice(W*H,K*H)}return this}validate(){let J=!0,Q=this.getValueSize();if(Q-Math.floor(Q)!==0)_0("KeyframeTrack: Invalid value size in track.",this),J=!1;let $=this.times,Z=this.values,W=$.length;if(W===0)_0("KeyframeTrack: Track is empty.",this),J=!1;let K=null;for(let H=0;H!==W;H++){let Y=$[H];if(typeof Y==="number"&&isNaN(Y)){_0("KeyframeTrack: Time is not a valid number.",this,H,Y),J=!1;break}if(K!==null&&K>Y){_0("KeyframeTrack: Out of order keys.",this,H,Y,K),J=!1;break}K=Y}if(Z!==void 0){if(xW(Z))for(let H=0,Y=Z.length;H!==Y;++H){let X=Z[H];if(isNaN(X)){_0("KeyframeTrack: Value is not a valid number.",this,H,X),J=!1;break}}}return J}optimize(){let J=this.times.slice(),Q=this.values.slice(),$=this.getValueSize(),Z=this.getInterpolation()===2302,W=J.length-1,K=1;for(let H=1;H<W;++H){let Y=!1,X=J[H],U=J[H+1];if(X!==U&&(H!==1||X!==J[0]))if(!Z){let E=H*$,N=E-$,G=E+$;for(let D=0;D!==$;++D){let M=Q[E+D];if(M!==Q[N+D]||M!==Q[G+D]){Y=!0;break}}}else Y=!0;if(Y){if(H!==K){J[K]=J[H];let E=H*$,N=K*$;for(let G=0;G!==$;++G)Q[N+G]=Q[E+G]}++K}}if(W>0){J[K]=J[W];for(let H=W*$,Y=K*$,X=0;X!==$;++X)Q[Y+X]=Q[H+X];++K}if(K!==J.length)this.times=J.slice(0,K),this.values=Q.slice(0,K*$);else this.times=J,this.values=Q;return this}clone(){let J=this.times.slice(),Q=this.values.slice(),Z=new this.constructor(this.name,J,Q);return Z.createInterpolant=this.createInterpolant,Z}}pJ.prototype.ValueTypeName="";pJ.prototype.TimeBufferType=Float32Array;pJ.prototype.ValueBufferType=Float32Array;pJ.prototype.DefaultInterpolation=2301;class n9 extends pJ{constructor(J,Q,$){super(J,Q,$)}}n9.prototype.ValueTypeName="bool";n9.prototype.ValueBufferType=Array;n9.prototype.DefaultInterpolation=2300;n9.prototype.InterpolantFactoryMethodLinear=void 0;n9.prototype.InterpolantFactoryMethodSmooth=void 0;class _Q extends pJ{constructor(J,Q,$,Z){super(J,Q,$,Z)}}_Q.prototype.ValueTypeName="color";class PQ extends pJ{constructor(J,Q,$,Z){super(J,Q,$,Z)}}PQ.prototype.ValueTypeName="number";class TQ extends c9{constructor(J,Q,$,Z){super(J,Q,$,Z)}interpolate_(J,Q,$,Z){let W=this.resultBuffer,K=this.sampleValues,H=this.valueSize,Y=($-Q)/(Z-Q),X=J*H;for(let U=X+H;X!==U;X+=4)q9.slerpFlat(W,0,K,X-H,K,X,Y);return W}}class f6 extends pJ{constructor(J,Q,$,Z){super(J,Q,$,Z)}InterpolantFactoryMethodLinear(J){return new TQ(this.times,this.values,this.getValueSize(),J)}}f6.prototype.ValueTypeName="quaternion";f6.prototype.InterpolantFactoryMethodSmooth=void 0;class s9 extends pJ{constructor(J,Q,$){super(J,Q,$)}}s9.prototype.ValueTypeName="string";s9.prototype.ValueBufferType=Array;s9.prototype.DefaultInterpolation=2300;s9.prototype.InterpolantFactoryMethodLinear=void 0;s9.prototype.InterpolantFactoryMethodSmooth=void 0;class SQ extends pJ{constructor(J,Q,$,Z){super(J,Q,$,Z)}}SQ.prototype.ValueTypeName="vector";class jQ{constructor(J,Q,$){let Z=this,W=!1,K=0,H=0,Y=void 0,X=[];this.onStart=void 0,this.onLoad=J,this.onProgress=Q,this.onError=$,this._abortController=null,this.itemStart=function(U){if(H++,W===!1){if(Z.onStart!==void 0)Z.onStart(U,K,H)}W=!0},this.itemEnd=function(U){if(K++,Z.onProgress!==void 0)Z.onProgress(U,K,H);if(K===H){if(W=!1,Z.onLoad!==void 0)Z.onLoad()}},this.itemError=function(U){if(Z.onError!==void 0)Z.onError(U)},this.resolveURL=function(U){if(U=U.normalize("NFC"),Y)return Y(U);return U},this.setURLModifier=function(U){return Y=U,this},this.addHandler=function(U,E){return X.push(U,E),this},this.removeHandler=function(U){let E=X.indexOf(U);if(E!==-1)X.splice(E,2);return this},this.getHandler=function(U){for(let E=0,N=X.length;E<N;E+=2){let G=X[E],D=X[E+1];if(G.global)G.lastIndex=0;if(G.test(U))return D}return null},this.abort=function(){return this.abortController.abort(),this._abortController=null,this}}get abortController(){if(!this._abortController)this._abortController=new AbortController;return this._abortController}}var hZ=new jQ;class yQ{constructor(J){if(this.manager=J!==void 0?J:hZ,this.crossOrigin="anonymous",this.withCredentials=!1,this.path="",this.resourcePath="",this.requestHeader={},typeof __THREE_DEVTOOLS__<"u")__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}load(){}loadAsync(J,Q){let $=this;return new Promise(function(Z,W){$.load(J,Z,Q,W)})}parse(){}setCrossOrigin(J){return this.crossOrigin=J,this}setWithCredentials(J){return this.withCredentials=J,this}setPath(J){return this.path=J,this}setResourcePath(J){return this.resourcePath=J,this}setRequestHeader(J){return this.requestHeader=J,this}abort(){return this}}yQ.DEFAULT_MATERIAL_NAME="__DEFAULT";class fQ extends BJ{constructor(J,Q=1){super();this.isLight=!0,this.type="Light",this.color=new g0(J),this.intensity=Q}dispose(){this.dispatchEvent({type:"dispose"})}copy(J,Q){return super.copy(J,Q),this.color.copy(J.color),this.intensity=J.intensity,this}toJSON(J){let Q=super.toJSON(J);return Q.object.color=this.color.getHex(),Q.object.intensity=this.intensity,Q}}var X6=new b,U6=new q9,aJ=new b;class v6 extends BJ{constructor(){super();this.isCamera=!0,this.type="Camera",this.matrixWorldInverse=new WJ,this.projectionMatrix=new WJ,this.projectionMatrixInverse=new WJ,this.coordinateSystem=2000,this._reversedDepth=!1}get reversedDepth(){return this._reversedDepth}copy(J,Q){return super.copy(J,Q),this.matrixWorldInverse.copy(J.matrixWorldInverse),this.projectionMatrix.copy(J.projectionMatrix),this.projectionMatrixInverse.copy(J.projectionMatrixInverse),this.coordinateSystem=J.coordinateSystem,this}getWorldDirection(J){return super.getWorldDirection(J).negate()}updateMatrixWorld(J){if(super.updateMatrixWorld(J),this.matrixWorld.decompose(X6,U6,aJ),aJ.x===1&&aJ.y===1&&aJ.z===1)this.matrixWorldInverse.copy(this.matrixWorld).invert();else this.matrixWorldInverse.compose(X6,U6,aJ.set(1,1,1)).invert()}updateWorldMatrix(J,Q,$=!1){if(super.updateWorldMatrix(J,Q,$),this.matrixWorld.decompose(X6,U6,aJ),aJ.x===1&&aJ.y===1&&aJ.z===1)this.matrixWorldInverse.copy(this.matrixWorld).invert();else this.matrixWorldInverse.compose(X6,U6,aJ.set(1,1,1)).invert()}clone(){return new this.constructor().copy(this)}}var z9=new b,S$=new u0,j$=new u0;class IJ extends v6{constructor(J=50,Q=1,$=0.1,Z=2000){super();this.isPerspectiveCamera=!0,this.type="PerspectiveCamera",this.fov=J,this.zoom=1,this.near=$,this.far=Z,this.focus=10,this.aspect=Q,this.view=null,this.filmGauge=35,this.filmOffset=0,this.updateProjectionMatrix()}copy(J,Q){return super.copy(J,Q),this.fov=J.fov,this.zoom=J.zoom,this.near=J.near,this.far=J.far,this.focus=J.focus,this.aspect=J.aspect,this.view=J.view===null?null:Object.assign({},J.view),this.filmGauge=J.filmGauge,this.filmOffset=J.filmOffset,this}setFocalLength(J){let Q=0.5*this.getFilmHeight()/J;this.fov=G6*2*Math.atan(Q),this.updateProjectionMatrix()}getFocalLength(){let J=Math.tan(c6*0.5*this.fov);return 0.5*this.getFilmHeight()/J}getEffectiveFOV(){return G6*2*Math.atan(Math.tan(c6*0.5*this.fov)/this.zoom)}getFilmWidth(){return this.filmGauge*Math.min(this.aspect,1)}getFilmHeight(){return this.filmGauge/Math.max(this.aspect,1)}getViewBounds(J,Q,$){z9.set(-1,-1,0.5).applyMatrix4(this.projectionMatrixInverse),Q.set(z9.x,z9.y).multiplyScalar(-J/z9.z),z9.set(1,1,0.5).applyMatrix4(this.projectionMatrixInverse),$.set(z9.x,z9.y).multiplyScalar(-J/z9.z)}getViewSize(J,Q){return this.getViewBounds(J,S$,j$),Q.subVectors(j$,S$)}setViewOffset(J,Q,$,Z,W,K){if(this.aspect=J/Q,this.view===null)this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1};this.view.enabled=!0,this.view.fullWidth=J,this.view.fullHeight=Q,this.view.offsetX=$,this.view.offsetY=Z,this.view.width=W,this.view.height=K,this.updateProjectionMatrix()}clearViewOffset(){if(this.view!==null)this.view.enabled=!1;this.updateProjectionMatrix()}updateProjectionMatrix(){let J=this.near,Q=J*Math.tan(c6*0.5*this.fov)/this.zoom,$=2*Q,Z=this.aspect*$,W=-0.5*Z,K=this.view;if(this.view!==null&&this.view.enabled){let{fullWidth:Y,fullHeight:X}=K;W+=K.offsetX*Z/Y,Q-=K.offsetY*$/X,Z*=K.width/Y,$*=K.height/X}let H=this.filmOffset;if(H!==0)W+=J*H/this.getFilmWidth();this.projectionMatrix.makePerspective(W,W+Z,Q,Q-$,J,this.far,this.coordinateSystem,this.reversedDepth),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(J){let Q=super.toJSON(J);if(Q.object.fov=this.fov,Q.object.zoom=this.zoom,Q.object.near=this.near,Q.object.far=this.far,Q.object.focus=this.focus,Q.object.aspect=this.aspect,this.view!==null)Q.object.view=Object.assign({},this.view);return Q.object.filmGauge=this.filmGauge,Q.object.filmOffset=this.filmOffset,Q}}class b6 extends v6{constructor(J=-1,Q=1,$=1,Z=-1,W=0.1,K=2000){super();this.isOrthographicCamera=!0,this.type="OrthographicCamera",this.zoom=1,this.view=null,this.left=J,this.right=Q,this.top=$,this.bottom=Z,this.near=W,this.far=K,this.updateProjectionMatrix()}copy(J,Q){return super.copy(J,Q),this.left=J.left,this.right=J.right,this.top=J.top,this.bottom=J.bottom,this.near=J.near,this.far=J.far,this.zoom=J.zoom,this.view=J.view===null?null:Object.assign({},J.view),this}setViewOffset(J,Q,$,Z,W,K){if(this.view===null)this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1};this.view.enabled=!0,this.view.fullWidth=J,this.view.fullHeight=Q,this.view.offsetX=$,this.view.offsetY=Z,this.view.width=W,this.view.height=K,this.updateProjectionMatrix()}clearViewOffset(){if(this.view!==null)this.view.enabled=!1;this.updateProjectionMatrix()}updateProjectionMatrix(){let J=(this.right-this.left)/(2*this.zoom),Q=(this.top-this.bottom)/(2*this.zoom),$=(this.right+this.left)/2,Z=(this.top+this.bottom)/2,W=$-J,K=$+J,H=Z+Q,Y=Z-Q;if(this.view!==null&&this.view.enabled){let X=(this.right-this.left)/this.view.fullWidth/this.zoom,U=(this.top-this.bottom)/this.view.fullHeight/this.zoom;W+=X*this.view.offsetX,K=W+X*this.view.width,H-=U*this.view.offsetY,Y=H-U*this.view.height}this.projectionMatrix.makeOrthographic(W,K,H,Y,this.near,this.far,this.coordinateSystem,this.reversedDepth),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(J){let Q=super.toJSON(J);if(Q.object.zoom=this.zoom,Q.object.left=this.left,Q.object.right=this.right,Q.object.top=this.top,Q.object.bottom=this.bottom,Q.object.near=this.near,Q.object.far=this.far,this.view!==null)Q.object.view=Object.assign({},this.view);return Q}}class h6 extends fQ{constructor(J,Q){super(J,Q);this.isAmbientLight=!0,this.type="AmbientLight"}}var Y8=-90,X8=1;class vQ extends BJ{constructor(J,Q,$){super();this.type="CubeCamera",this.renderTarget=$,this.coordinateSystem=null,this.activeMipmapLevel=0;let Z=new IJ(Y8,X8,J,Q);Z.layers=this.layers,this.add(Z);let W=new IJ(Y8,X8,J,Q);W.layers=this.layers,this.add(W);let K=new IJ(Y8,X8,J,Q);K.layers=this.layers,this.add(K);let H=new IJ(Y8,X8,J,Q);H.layers=this.layers,this.add(H);let Y=new IJ(Y8,X8,J,Q);Y.layers=this.layers,this.add(Y);let X=new IJ(Y8,X8,J,Q);X.layers=this.layers,this.add(X)}updateCoordinateSystem(){let J=this.coordinateSystem,Q=this.children.concat(),[$,Z,W,K,H,Y]=Q;for(let X of Q)this.remove(X);if(J===2000)$.up.set(0,1,0),$.lookAt(1,0,0),Z.up.set(0,1,0),Z.lookAt(-1,0,0),W.up.set(0,0,-1),W.lookAt(0,1,0),K.up.set(0,0,1),K.lookAt(0,-1,0),H.up.set(0,1,0),H.lookAt(0,0,1),Y.up.set(0,1,0),Y.lookAt(0,0,-1);else if(J===2001)$.up.set(0,-1,0),$.lookAt(-1,0,0),Z.up.set(0,-1,0),Z.lookAt(1,0,0),W.up.set(0,0,1),W.lookAt(0,1,0),K.up.set(0,0,-1),K.lookAt(0,-1,0),H.up.set(0,-1,0),H.lookAt(0,0,1),Y.up.set(0,-1,0),Y.lookAt(0,0,-1);else throw Error("THREE.CubeCamera.updateCoordinateSystem(): Invalid coordinate system: "+J);for(let X of Q)this.add(X),X.updateMatrixWorld()}update(J,Q){if(this.parent===null)this.updateMatrixWorld();let{renderTarget:$,activeMipmapLevel:Z}=this;if(this.coordinateSystem!==J.coordinateSystem)this.coordinateSystem=J.coordinateSystem,this.updateCoordinateSystem();let[W,K,H,Y,X,U]=this.children,E=J.getRenderTarget(),N=J.getActiveCubeFace(),G=J.getActiveMipmapLevel(),D=J.xr.enabled;J.xr.enabled=!1;let M=$.texture.generateMipmaps;$.texture.generateMipmaps=!1;let z=!1;if(J.isWebGLRenderer===!0)z=J.state.buffers.depth.getReversed();else z=J.reversedDepthBuffer;if(J.setRenderTarget($,0,Z),z&&J.autoClear===!1)J.clearDepth();if(J.render(Q,W),J.setRenderTarget($,1,Z),z&&J.autoClear===!1)J.clearDepth();if(J.render(Q,K),J.setRenderTarget($,2,Z),z&&J.autoClear===!1)J.clearDepth();if(J.render(Q,H),J.setRenderTarget($,3,Z),z&&J.autoClear===!1)J.clearDepth();if(J.render(Q,Y),J.setRenderTarget($,4,Z),z&&J.autoClear===!1)J.clearDepth();if(J.render(Q,X),$.texture.generateMipmaps=M,J.setRenderTarget($,5,Z),z&&J.autoClear===!1)J.clearDepth();J.render(Q,U),J.setRenderTarget(E,N,G),J.xr.enabled=D,$.texture.needsPMREMUpdate=!0}}class bQ extends IJ{constructor(J=[]){super();this.isArrayCamera=!0,this.isMultiViewCamera=!1,this.cameras=J}}var hQ="\\[\\]\\.:\\/",YK=new RegExp("["+hQ+"]","g"),xQ="[^"+hQ+"]",XK="[^"+hQ.replace("\\.","")+"]",UK=/((?:WC+[\/:])*)/.source.replace("WC",xQ),GK=/(WCOD+)?/.source.replace("WCOD",XK),EK=/(?:\.(WC+)(?:\[(.+)\])?)?/.source.replace("WC",xQ),NK=/\.(WC+)(?:\[(.+)\])?/.source.replace("WC",xQ),qK=new RegExp("^"+UK+GK+EK+NK+"$"),FK=["material","materials","bones","map"];class xZ{constructor(J,Q,$){let Z=$||n0.parseTrackName(Q);this._targetGroup=J,this._bindings=J.subscribe_(Q,Z)}getValue(J,Q){this.bind();let $=this._targetGroup.nCachedObjects_,Z=this._bindings[$];if(Z!==void 0)Z.getValue(J,Q)}setValue(J,Q){let $=this._bindings;for(let Z=this._targetGroup.nCachedObjects_,W=$.length;Z!==W;++Z)$[Z].setValue(J,Q)}bind(){let J=this._bindings;for(let Q=this._targetGroup.nCachedObjects_,$=J.length;Q!==$;++Q)J[Q].bind()}unbind(){let J=this._bindings;for(let Q=this._targetGroup.nCachedObjects_,$=J.length;Q!==$;++Q)J[Q].unbind()}}class n0{constructor(J,Q,$){this.path=Q,this.parsedPath=$||n0.parseTrackName(Q),this.node=n0.findNode(J,this.parsedPath.nodeName),this.rootNode=J,this.getValue=this._getValue_unbound,this.setValue=this._setValue_unbound}static create(J,Q,$){if(!(J&&J.isAnimationObjectGroup))return new n0(J,Q,$);else return new n0.Composite(J,Q,$)}static sanitizeNodeName(J){return J.replace(/\s/g,"_").replace(YK,"")}static parseTrackName(J){let Q=qK.exec(J);if(Q===null)throw Error("THREE.PropertyBinding: Cannot parse trackName: "+J);let $={nodeName:Q[2],objectName:Q[3],objectIndex:Q[4],propertyName:Q[5],propertyIndex:Q[6]},Z=$.nodeName&&$.nodeName.lastIndexOf(".");if(Z!==void 0&&Z!==-1){let W=$.nodeName.substring(Z+1);if(FK.indexOf(W)!==-1)$.nodeName=$.nodeName.substring(0,Z),$.objectName=W}if($.propertyName===null||$.propertyName.length===0)throw Error("THREE.PropertyBinding: can not parse propertyName from trackName: "+J);return $}static findNode(J,Q){if(Q===void 0||Q===""||Q==="."||Q===-1||Q===J.name||Q===J.uuid)return J;if(J.skeleton){let $=J.skeleton.getBoneByName(Q);if($!==void 0)return $}if(J.children){let $=function(W){for(let K=0;K<W.length;K++){let H=W[K];if(H.name===Q||H.uuid===Q)return H;let Y=$(H.children);if(Y)return Y}return null},Z=$(J.children);if(Z)return Z}return null}_getValue_unavailable(){}_setValue_unavailable(){}_getValue_direct(J,Q){J[Q]=this.targetObject[this.propertyName]}_getValue_array(J,Q){let $=this.resolvedProperty;for(let Z=0,W=$.length;Z!==W;++Z)J[Q++]=$[Z]}_getValue_arrayElement(J,Q){J[Q]=this.resolvedProperty[this.propertyIndex]}_getValue_toArray(J,Q){this.resolvedProperty.toArray(J,Q)}_setValue_direct(J,Q){this.targetObject[this.propertyName]=J[Q]}_setValue_direct_setNeedsUpdate(J,Q){this.targetObject[this.propertyName]=J[Q],this.targetObject.needsUpdate=!0}_setValue_direct_setMatrixWorldNeedsUpdate(J,Q){this.targetObject[this.propertyName]=J[Q],this.targetObject.matrixWorldNeedsUpdate=!0}_setValue_array(J,Q){let $=this.resolvedProperty;for(let Z=0,W=$.length;Z!==W;++Z)$[Z]=J[Q++]}_setValue_array_setNeedsUpdate(J,Q){let $=this.resolvedProperty;for(let Z=0,W=$.length;Z!==W;++Z)$[Z]=J[Q++];this.targetObject.needsUpdate=!0}_setValue_array_setMatrixWorldNeedsUpdate(J,Q){let $=this.resolvedProperty;for(let Z=0,W=$.length;Z!==W;++Z)$[Z]=J[Q++];this.targetObject.matrixWorldNeedsUpdate=!0}_setValue_arrayElement(J,Q){this.resolvedProperty[this.propertyIndex]=J[Q]}_setValue_arrayElement_setNeedsUpdate(J,Q){this.resolvedProperty[this.propertyIndex]=J[Q],this.targetObject.needsUpdate=!0}_setValue_arrayElement_setMatrixWorldNeedsUpdate(J,Q){this.resolvedProperty[this.propertyIndex]=J[Q],this.targetObject.matrixWorldNeedsUpdate=!0}_setValue_fromArray(J,Q){this.resolvedProperty.fromArray(J,Q)}_setValue_fromArray_setNeedsUpdate(J,Q){this.resolvedProperty.fromArray(J,Q),this.targetObject.needsUpdate=!0}_setValue_fromArray_setMatrixWorldNeedsUpdate(J,Q){this.resolvedProperty.fromArray(J,Q),this.targetObject.matrixWorldNeedsUpdate=!0}_getValue_unbound(J,Q){this.bind(),this.getValue(J,Q)}_setValue_unbound(J,Q){this.bind(),this.setValue(J,Q)}bind(){let J=this.node,Q=this.parsedPath,$=Q.objectName,Z=Q.propertyName,W=Q.propertyIndex;if(!J)J=n0.findNode(this.rootNode,Q.nodeName),this.node=J;if(this.getValue=this._getValue_unavailable,this.setValue=this._setValue_unavailable,!J){C0("PropertyBinding: No target node found for track: "+this.path+".");return}if($){let X=Q.objectIndex;switch($){case"materials":if(!J.material){_0("PropertyBinding: Can not bind to material as node does not have a material.",this);return}if(!J.material.materials){_0("PropertyBinding: Can not bind to material.materials as node.material does not have a materials array.",this);return}J=J.material.materials;break;case"bones":if(!J.skeleton){_0("PropertyBinding: Can not bind to bones as node does not have a skeleton.",this);return}J=J.skeleton.bones;for(let U=0;U<J.length;U++)if(J[U].name===X){X=U;break}break;case"map":if("map"in J){J=J.map;break}if(!J.material){_0("PropertyBinding: Can not bind to material as node does not have a material.",this);return}if(!J.material.map){_0("PropertyBinding: Can not bind to material.map as node.material does not have a map.",this);return}J=J.material.map;break;default:if(J[$]===void 0){_0("PropertyBinding: Can not bind to objectName of node undefined.",this);return}J=J[$]}if(X!==void 0){if(J[X]===void 0){_0("PropertyBinding: Trying to bind to objectIndex of objectName, but is undefined.",this,J);return}J=J[X]}}let K=J[Z];if(K===void 0){let X=Q.nodeName;_0("PropertyBinding: Trying to update property for track: "+X+"."+Z+" but it wasn't found.",J);return}let H=this.Versioning.None;if(this.targetObject=J,J.isMaterial===!0)H=this.Versioning.NeedsUpdate;else if(J.isObject3D===!0)H=this.Versioning.MatrixWorldNeedsUpdate;let Y=this.BindingType.Direct;if(W!==void 0){if(Z==="morphTargetInfluences"){if(!J.geometry){_0("PropertyBinding: Can not bind to morphTargetInfluences because node does not have a geometry.",this);return}if(!J.geometry.morphAttributes){_0("PropertyBinding: Can not bind to morphTargetInfluences because node does not have a geometry.morphAttributes.",this);return}if(J.morphTargetDictionary[W]!==void 0)W=J.morphTargetDictionary[W]}Y=this.BindingType.ArrayElement,this.resolvedProperty=K,this.propertyIndex=W}else if(K.fromArray!==void 0&&K.toArray!==void 0)Y=this.BindingType.HasFromToArray,this.resolvedProperty=K;else if(Array.isArray(K))Y=this.BindingType.EntireArray,this.resolvedProperty=K;else this.propertyName=Z;this.getValue=this.GetterByBindingType[Y],this.setValue=this.SetterByBindingTypeAndVersioning[Y][H]}unbind(){this.node=null,this.getValue=this._getValue_unbound,this.setValue=this._setValue_unbound}}n0.Composite=xZ;n0.prototype.BindingType={Direct:0,EntireArray:1,ArrayElement:2,HasFromToArray:3};n0.prototype.Versioning={None:0,NeedsUpdate:1,MatrixWorldNeedsUpdate:2};n0.prototype.GetterByBindingType=[n0.prototype._getValue_direct,n0.prototype._getValue_array,n0.prototype._getValue_arrayElement,n0.prototype._getValue_toArray];n0.prototype.SetterByBindingTypeAndVersioning=[[n0.prototype._setValue_direct,n0.prototype._setValue_direct_setNeedsUpdate,n0.prototype._setValue_direct_setMatrixWorldNeedsUpdate],[n0.prototype._setValue_array,n0.prototype._setValue_array_setNeedsUpdate,n0.prototype._setValue_array_setMatrixWorldNeedsUpdate],[n0.prototype._setValue_arrayElement,n0.prototype._setValue_arrayElement_setNeedsUpdate,n0.prototype._setValue_arrayElement_setMatrixWorldNeedsUpdate],[n0.prototype._setValue_fromArray,n0.prototype._setValue_fromArray_setNeedsUpdate,n0.prototype._setValue_fromArray_setMatrixWorldNeedsUpdate]];var RG=new Float32Array(1);class gQ{static{gQ.prototype.isMatrix2=!0}constructor(J,Q,$,Z){if(this.elements=[1,0,0,1],J!==void 0)this.set(J,Q,$,Z)}identity(){return this.set(1,0,0,1),this}fromArray(J,Q=0){for(let $=0;$<4;$++)this.elements[$]=J[$+Q];return this}set(J,Q,$,Z){let W=this.elements;return W[0]=J,W[2]=Q,W[1]=$,W[3]=Z,this}}function pQ(J,Q,$,Z){let W=DK(Z);switch($){case 1021:return J*Q;case 1028:return J*Q/W.components*W.byteLength;case 1029:return J*Q/W.components*W.byteLength;case 1030:return J*Q*2/W.components*W.byteLength;case 1031:return J*Q*2/W.components*W.byteLength;case 1022:return J*Q*3/W.components*W.byteLength;case 1023:return J*Q*4/W.components*W.byteLength;case 1033:return J*Q*4/W.components*W.byteLength;case 33776:case 33777:return Math.floor((J+3)/4)*Math.floor((Q+3)/4)*8;case 33778:case 33779:return Math.floor((J+3)/4)*Math.floor((Q+3)/4)*16;case 35841:case 35843:return Math.max(J,16)*Math.max(Q,8)/4;case 35840:case 35842:return Math.max(J,8)*Math.max(Q,8)/2;case 36196:case 37492:case 37488:case 37489:return Math.floor((J+3)/4)*Math.floor((Q+3)/4)*8;case 37496:case 37490:case 37491:return Math.floor((J+3)/4)*Math.floor((Q+3)/4)*16;case 37808:return Math.floor((J+3)/4)*Math.floor((Q+3)/4)*16;case 37809:return Math.floor((J+4)/5)*Math.floor((Q+3)/4)*16;case 37810:return Math.floor((J+4)/5)*Math.floor((Q+4)/5)*16;case 37811:return Math.floor((J+5)/6)*Math.floor((Q+4)/5)*16;case 37812:return Math.floor((J+5)/6)*Math.floor((Q+5)/6)*16;case 37813:return Math.floor((J+7)/8)*Math.floor((Q+4)/5)*16;case 37814:return Math.floor((J+7)/8)*Math.floor((Q+5)/6)*16;case 37815:return Math.floor((J+7)/8)*Math.floor((Q+7)/8)*16;case 37816:return Math.floor((J+9)/10)*Math.floor((Q+4)/5)*16;case 37817:return Math.floor((J+9)/10)*Math.floor((Q+5)/6)*16;case 37818:return Math.floor((J+9)/10)*Math.floor((Q+7)/8)*16;case 37819:return Math.floor((J+9)/10)*Math.floor((Q+9)/10)*16;case 37820:return Math.floor((J+11)/12)*Math.floor((Q+9)/10)*16;case 37821:return Math.floor((J+11)/12)*Math.floor((Q+11)/12)*16;case 36492:case 36494:case 36495:return Math.ceil(J/4)*Math.ceil(Q/4)*16;case 36283:case 36284:return Math.ceil(J/4)*Math.ceil(Q/4)*8;case 36285:case 36286:return Math.ceil(J/4)*Math.ceil(Q/4)*16}throw Error(`Unable to determine texture byte length for ${$} format.`)}function DK(J){switch(J){case 1009:case 1010:return{byteLength:1,components:1};case 1012:case 1011:case 1016:return{byteLength:2,components:1};case 1017:case 1018:return{byteLength:2,components:4};case 1014:case 1013:case 1015:return{byteLength:4,components:1};case 35902:case 35899:return{byteLength:4,components:3}}throw Error(`THREE.TextureUtils: Unknown texture type ${J}.`)}if(typeof __THREE_DEVTOOLS__<"u")__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("register",{detail:{revision:"185"}}));if(typeof window<"u")if(window.__THREE__)C0("WARNING: Multiple instances of Three.js being imported.");else window.__THREE__="185";function YW(){let J=null,Q=!1,$=null,Z=null;function W(K,H){$(K,H),Z=J.requestAnimationFrame(W)}return{start:function(){if(Q===!0)return;if($===null)return;if(J===null)return;Z=J.requestAnimationFrame(W),Q=!0},stop:function(){if(J!==null)J.cancelAnimationFrame(Z);Q=!1},setAnimationLoop:function(K){$=K},setContext:function(K){J=K}}}function RK(J){let Q=new WeakMap;function $(Y,X){let{array:U,usage:E}=Y,N=U.byteLength,G=J.createBuffer();J.bindBuffer(X,G),J.bufferData(X,U,E),Y.onUploadCallback();let D;if(U instanceof Float32Array)D=J.FLOAT;else if(typeof Float16Array<"u"&&U instanceof Float16Array)D=J.HALF_FLOAT;else if(U instanceof Uint16Array)if(Y.isFloat16BufferAttribute)D=J.HALF_FLOAT;else D=J.UNSIGNED_SHORT;else if(U instanceof Int16Array)D=J.SHORT;else if(U instanceof Uint32Array)D=J.UNSIGNED_INT;else if(U instanceof Int32Array)D=J.INT;else if(U instanceof Int8Array)D=J.BYTE;else if(U instanceof Uint8Array)D=J.UNSIGNED_BYTE;else if(U instanceof Uint8ClampedArray)D=J.UNSIGNED_BYTE;else throw Error("THREE.WebGLAttributes: Unsupported buffer data format: "+U);return{buffer:G,type:D,bytesPerElement:U.BYTES_PER_ELEMENT,version:Y.version,size:N}}function Z(Y,X,U){let{array:E,updateRanges:N}=X;if(J.bindBuffer(U,Y),N.length===0)J.bufferSubData(U,0,E);else{N.sort((D,M)=>D.start-M.start);let G=0;for(let D=1;D<N.length;D++){let M=N[G],z=N[D];if(z.start<=M.start+M.count+1)M.count=Math.max(M.count,z.start+z.count-M.start);else++G,N[G]=z}N.length=G+1;for(let D=0,M=N.length;D<M;D++){let z=N[D];J.bufferSubData(U,z.start*E.BYTES_PER_ELEMENT,E,z.start,z.count)}X.clearUpdateRanges()}X.onUploadCallback()}function W(Y){if(Y.isInterleavedBufferAttribute)Y=Y.data;return Q.get(Y)}function K(Y){if(Y.isInterleavedBufferAttribute)Y=Y.data;let X=Q.get(Y);if(X)J.deleteBuffer(X.buffer),Q.delete(Y)}function H(Y,X){if(Y.isInterleavedBufferAttribute)Y=Y.data;if(Y.isGLBufferAttribute){let E=Q.get(Y);if(!E||E.version<Y.version)Q.set(Y,{buffer:Y.buffer,type:Y.type,bytesPerElement:Y.elementSize,version:Y.version});return}let U=Q.get(Y);if(U===void 0)Q.set(Y,$(Y,X));else if(U.version<Y.version){if(U.size!==Y.array.byteLength)throw Error("THREE.WebGLAttributes: The size of the buffer attribute's array buffer does not match the original size. Resizing buffer attributes is not supported.");Z(U.buffer,Y,X),U.version=Y.version}}return{get:W,remove:K,update:H}}var OK=`#ifdef USE_ALPHAHASH
	if ( diffuseColor.a < getAlphaHashThreshold( vPosition ) ) discard;
#endif`,kK=`#ifdef USE_ALPHAHASH
	const float ALPHA_HASH_SCALE = 0.05;
	float hash2D( vec2 value ) {
		return fract( 1.0e4 * sin( 17.0 * value.x + 0.1 * value.y ) * ( 0.1 + abs( sin( 13.0 * value.y + value.x ) ) ) );
	}
	float hash3D( vec3 value ) {
		return hash2D( vec2( hash2D( value.xy ), value.z ) );
	}
	float getAlphaHashThreshold( vec3 position ) {
		float maxDeriv = max(
			length( dFdx( position.xyz ) ),
			length( dFdy( position.xyz ) )
		);
		float pixScale = 1.0 / ( ALPHA_HASH_SCALE * maxDeriv );
		vec2 pixScales = vec2(
			exp2( floor( log2( pixScale ) ) ),
			exp2( ceil( log2( pixScale ) ) )
		);
		vec2 alpha = vec2(
			hash3D( floor( pixScales.x * position.xyz ) ),
			hash3D( floor( pixScales.y * position.xyz ) )
		);
		float lerpFactor = fract( log2( pixScale ) );
		float x = ( 1.0 - lerpFactor ) * alpha.x + lerpFactor * alpha.y;
		float a = min( lerpFactor, 1.0 - lerpFactor );
		vec3 cases = vec3(
			x * x / ( 2.0 * a * ( 1.0 - a ) ),
			( x - 0.5 * a ) / ( 1.0 - a ),
			1.0 - ( ( 1.0 - x ) * ( 1.0 - x ) / ( 2.0 * a * ( 1.0 - a ) ) )
		);
		float threshold = ( x < ( 1.0 - a ) )
			? ( ( x < a ) ? cases.x : cases.y )
			: cases.z;
		return clamp( threshold , 1.0e-6, 1.0 );
	}
#endif`,MK=`#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, vAlphaMapUv ).g;
#endif`,LK=`#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,VK=`#ifdef USE_ALPHATEST
	#ifdef ALPHA_TO_COVERAGE
	diffuseColor.a = smoothstep( alphaTest, alphaTest + fwidth( diffuseColor.a ), diffuseColor.a );
	if ( diffuseColor.a == 0.0 ) discard;
	#else
	if ( diffuseColor.a < alphaTest ) discard;
	#endif
#endif`,BK=`#ifdef USE_ALPHATEST
	uniform float alphaTest;
#endif`,zK=`#ifdef USE_AOMAP
	float ambientOcclusion = ( texture2D( aoMap, vAoMapUv ).r - 1.0 ) * aoMapIntensity + 1.0;
	reflectedLight.indirectDiffuse *= ambientOcclusion;
	#if defined( USE_CLEARCOAT ) 
		clearcoatSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_SHEEN ) 
		sheenSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_ENVMAP ) && defined( STANDARD )
		float dotNV = saturate( dot( geometryNormal, geometryViewDir ) );
		reflectedLight.indirectSpecular *= computeSpecularOcclusion( dotNV, ambientOcclusion, material.roughness );
	#endif
#endif`,IK=`#ifdef USE_AOMAP
	uniform sampler2D aoMap;
	uniform float aoMapIntensity;
#endif`,AK=`#ifdef USE_BATCHING
	#if ! defined( GL_ANGLE_multi_draw )
	#define gl_DrawID _gl_DrawID
	uniform int _gl_DrawID;
	#endif
	uniform highp sampler2D batchingTexture;
	uniform highp usampler2D batchingIdTexture;
	mat4 getBatchingMatrix( const in float i ) {
		int size = textureSize( batchingTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( batchingTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( batchingTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( batchingTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( batchingTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
	float getIndirectIndex( const in int i ) {
		int size = textureSize( batchingIdTexture, 0 ).x;
		int x = i % size;
		int y = i / size;
		return float( texelFetch( batchingIdTexture, ivec2( x, y ), 0 ).r );
	}
#endif
#ifdef USE_BATCHING_COLOR
	uniform sampler2D batchingColorTexture;
	vec4 getBatchingColor( const in float i ) {
		int size = textureSize( batchingColorTexture, 0 ).x;
		int j = int( i );
		int x = j % size;
		int y = j / size;
		return texelFetch( batchingColorTexture, ivec2( x, y ), 0 );
	}
#endif`,wK=`#ifdef USE_BATCHING
	mat4 batchingMatrix = getBatchingMatrix( getIndirectIndex( gl_DrawID ) );
#endif`,CK=`vec3 transformed = vec3( position );
#ifdef USE_ALPHAHASH
	vPosition = vec3( position );
#endif`,_K=`vec3 objectNormal = vec3( normal );
#ifdef USE_TANGENT
	vec3 objectTangent = vec3( tangent.xyz );
#endif`,PK=`float G_BlinnPhong_Implicit( ) {
	return 0.25;
}
float D_BlinnPhong( const in float shininess, const in float dotNH ) {
	return RECIPROCAL_PI * ( shininess * 0.5 + 1.0 ) * pow( dotNH, shininess );
}
vec3 BRDF_BlinnPhong( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in vec3 specularColor, const in float shininess ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( specularColor, 1.0, dotVH );
	float G = G_BlinnPhong_Implicit( );
	float D = D_BlinnPhong( shininess, dotNH );
	return F * ( G * D );
} // validated`,TK=`#ifdef USE_IRIDESCENCE
	const mat3 XYZ_TO_REC709 = mat3(
		 3.2404542, -0.9692660,  0.0556434,
		-1.5371385,  1.8760108, -0.2040259,
		-0.4985314,  0.0415560,  1.0572252
	);
	vec3 Fresnel0ToIor( vec3 fresnel0 ) {
		vec3 sqrtF0 = sqrt( fresnel0 );
		return ( vec3( 1.0 ) + sqrtF0 ) / ( vec3( 1.0 ) - sqrtF0 );
	}
	vec3 IorToFresnel0( vec3 transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - vec3( incidentIor ) ) / ( transmittedIor + vec3( incidentIor ) ) );
	}
	float IorToFresnel0( float transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - incidentIor ) / ( transmittedIor + incidentIor ));
	}
	vec3 evalSensitivity( float OPD, vec3 shift ) {
		float phase = 2.0 * PI * OPD * 1.0e-9;
		vec3 val = vec3( 5.4856e-13, 4.4201e-13, 5.2481e-13 );
		vec3 pos = vec3( 1.6810e+06, 1.7953e+06, 2.2084e+06 );
		vec3 var = vec3( 4.3278e+09, 9.3046e+09, 6.6121e+09 );
		vec3 xyz = val * sqrt( 2.0 * PI * var ) * cos( pos * phase + shift ) * exp( - pow2( phase ) * var );
		xyz.x += 9.7470e-14 * sqrt( 2.0 * PI * 4.5282e+09 ) * cos( 2.2399e+06 * phase + shift[ 0 ] ) * exp( - 4.5282e+09 * pow2( phase ) );
		xyz /= 1.0685e-7;
		vec3 rgb = XYZ_TO_REC709 * xyz;
		return rgb;
	}
	vec3 evalIridescence( float outsideIOR, float eta2, float cosTheta1, float thinFilmThickness, vec3 baseF0 ) {
		vec3 I;
		float iridescenceIOR = mix( outsideIOR, eta2, smoothstep( 0.0, 0.03, thinFilmThickness ) );
		float sinTheta2Sq = pow2( outsideIOR / iridescenceIOR ) * ( 1.0 - pow2( cosTheta1 ) );
		float cosTheta2Sq = 1.0 - sinTheta2Sq;
		if ( cosTheta2Sq < 0.0 ) {
			return vec3( 1.0 );
		}
		float cosTheta2 = sqrt( cosTheta2Sq );
		float R0 = IorToFresnel0( iridescenceIOR, outsideIOR );
		float R12 = F_Schlick( R0, 1.0, cosTheta1 );
		float T121 = 1.0 - R12;
		float phi12 = 0.0;
		if ( iridescenceIOR < outsideIOR ) phi12 = PI;
		float phi21 = PI - phi12;
		vec3 baseIOR = Fresnel0ToIor( clamp( baseF0, 0.0, 0.9999 ) );		vec3 R1 = IorToFresnel0( baseIOR, iridescenceIOR );
		vec3 R23 = F_Schlick( R1, 1.0, cosTheta2 );
		vec3 phi23 = vec3( 0.0 );
		if ( baseIOR[ 0 ] < iridescenceIOR ) phi23[ 0 ] = PI;
		if ( baseIOR[ 1 ] < iridescenceIOR ) phi23[ 1 ] = PI;
		if ( baseIOR[ 2 ] < iridescenceIOR ) phi23[ 2 ] = PI;
		float OPD = 2.0 * iridescenceIOR * thinFilmThickness * cosTheta2;
		vec3 phi = vec3( phi21 ) + phi23;
		vec3 R123 = clamp( R12 * R23, 1e-5, 0.9999 );
		vec3 r123 = sqrt( R123 );
		vec3 Rs = pow2( T121 ) * R23 / ( vec3( 1.0 ) - R123 );
		vec3 C0 = R12 + Rs;
		I = C0;
		vec3 Cm = Rs - T121;
		for ( int m = 1; m <= 2; ++ m ) {
			Cm *= r123;
			vec3 Sm = 2.0 * evalSensitivity( float( m ) * OPD, float( m ) * phi );
			I += Cm * Sm;
		}
		return max( I, vec3( 0.0 ) );
	}
#endif`,SK=`#ifdef USE_BUMPMAP
	uniform sampler2D bumpMap;
	uniform float bumpScale;
	vec2 dHdxy_fwd() {
		vec2 dSTdx = dFdx( vBumpMapUv );
		vec2 dSTdy = dFdy( vBumpMapUv );
		float Hll = bumpScale * texture2D( bumpMap, vBumpMapUv ).x;
		float dBx = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdx ).x - Hll;
		float dBy = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdy ).x - Hll;
		return vec2( dBx, dBy );
	}
	vec3 perturbNormalArb( vec3 surf_pos, vec3 surf_norm, vec2 dHdxy, float faceDirection ) {
		vec3 vSigmaX = normalize( dFdx( surf_pos.xyz ) );
		vec3 vSigmaY = normalize( dFdy( surf_pos.xyz ) );
		vec3 vN = surf_norm;
		vec3 R1 = cross( vSigmaY, vN );
		vec3 R2 = cross( vN, vSigmaX );
		float fDet = dot( vSigmaX, R1 ) * faceDirection;
		vec3 vGrad = sign( fDet ) * ( dHdxy.x * R1 + dHdxy.y * R2 );
		return normalize( abs( fDet ) * surf_norm - vGrad );
	}
#endif`,jK=`#if NUM_CLIPPING_PLANES > 0
	vec4 plane;
	#ifdef ALPHA_TO_COVERAGE
		float distanceToPlane, distanceGradient;
		float clipOpacity = 1.0;
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
			distanceGradient = fwidth( distanceToPlane ) / 2.0;
			clipOpacity *= smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			if ( clipOpacity == 0.0 ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			float unionClipOpacity = 1.0;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
				distanceGradient = fwidth( distanceToPlane ) / 2.0;
				unionClipOpacity *= 1.0 - smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			}
			#pragma unroll_loop_end
			clipOpacity *= 1.0 - unionClipOpacity;
		#endif
		diffuseColor.a *= clipOpacity;
		if ( diffuseColor.a == 0.0 ) discard;
	#else
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			if ( dot( vClipPosition, plane.xyz ) > plane.w ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			bool clipped = true;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				clipped = ( dot( vClipPosition, plane.xyz ) > plane.w ) && clipped;
			}
			#pragma unroll_loop_end
			if ( clipped ) discard;
		#endif
	#endif
#endif`,yK=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
	uniform vec4 clippingPlanes[ NUM_CLIPPING_PLANES ];
#endif`,fK=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
#endif`,vK=`#if NUM_CLIPPING_PLANES > 0
	vClipPosition = - mvPosition.xyz;
#endif`,bK=`#if defined( USE_COLOR ) || defined( USE_COLOR_ALPHA )
	diffuseColor *= vColor;
#endif`,hK=`#if defined( USE_COLOR ) || defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#endif`,xK=`#if defined( USE_COLOR ) || defined( USE_COLOR_ALPHA ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	varying vec4 vColor;
#endif`,gK=`#if defined( USE_COLOR ) || defined( USE_COLOR_ALPHA ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	vColor = vec4( 1.0 );
#endif
#ifdef USE_COLOR_ALPHA
	vColor *= color;
#elif defined( USE_COLOR )
	vColor.rgb *= color;
#endif
#ifdef USE_INSTANCING_COLOR
	vColor.rgb *= instanceColor.rgb;
#endif
#ifdef USE_BATCHING_COLOR
	vColor *= getBatchingColor( getIndirectIndex( gl_DrawID ) );
#endif`,pK=`#define PI 3.141592653589793
#define PI2 6.283185307179586
#define PI_HALF 1.5707963267948966
#define RECIPROCAL_PI 0.3183098861837907
#define RECIPROCAL_PI2 0.15915494309189535
#define EPSILON 1e-6
#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
#define whiteComplement( a ) ( 1.0 - saturate( a ) )
float pow2( const in float x ) { return x*x; }
vec3 pow2( const in vec3 x ) { return x*x; }
float pow3( const in float x ) { return x*x*x; }
float pow4( const in float x ) { float x2 = x*x; return x2*x2; }
float max3( const in vec3 v ) { return max( max( v.x, v.y ), v.z ); }
float average( const in vec3 v ) { return dot( v, vec3( 0.3333333 ) ); }
highp float rand( const in vec2 uv ) {
	const highp float a = 12.9898, b = 78.233, c = 43758.5453;
	highp float dt = dot( uv.xy, vec2( a,b ) ), sn = mod( dt, PI );
	return fract( sin( sn ) * c );
}
#ifdef HIGH_PRECISION
	float precisionSafeLength( vec3 v ) { return length( v ); }
#else
	float precisionSafeLength( vec3 v ) {
		float maxComponent = max3( abs( v ) );
		return length( v / maxComponent ) * maxComponent;
	}
#endif
struct IncidentLight {
	vec3 color;
	vec3 direction;
	bool visible;
};
struct ReflectedLight {
	vec3 directDiffuse;
	vec3 directSpecular;
	vec3 indirectDiffuse;
	vec3 indirectSpecular;
};
#ifdef USE_ALPHAHASH
	varying vec3 vPosition;
#endif
vec3 transformDirection( in vec3 dir, in mat4 matrix ) {
	return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );
}
#define inverseTransformDirection transformDirectionByInverseViewMatrix
vec3 transformNormalByInverseViewMatrix( in vec3 normal, in mat4 viewMatrix ) {
	return normalize( ( vec4( normal, 0.0 ) * viewMatrix ).xyz );
}
vec3 transformDirectionByInverseViewMatrix( in vec3 dir, in mat4 viewMatrix ) {
	return normalize( ( vec4( dir, 0.0 ) * viewMatrix ).xyz );
}
bool isPerspectiveMatrix( mat4 m ) {
	return m[ 2 ][ 3 ] == - 1.0;
}
vec2 equirectUv( in vec3 dir ) {
	float u = atan( dir.z, dir.x ) * RECIPROCAL_PI2 + 0.5;
	float v = asin( clamp( dir.y, - 1.0, 1.0 ) ) * RECIPROCAL_PI + 0.5;
	return vec2( u, v );
}
vec3 BRDF_Lambert( const in vec3 diffuseColor ) {
	return RECIPROCAL_PI * diffuseColor;
}
vec3 F_Schlick( const in vec3 f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
}
float F_Schlick( const in float f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
} // validated`,mK=`#ifdef ENVMAP_TYPE_CUBE_UV
	#define cubeUV_minMipLevel 4.0
	#define cubeUV_minTileSize 16.0
	float getFace( vec3 direction ) {
		vec3 absDirection = abs( direction );
		float face = - 1.0;
		if ( absDirection.x > absDirection.z ) {
			if ( absDirection.x > absDirection.y )
				face = direction.x > 0.0 ? 0.0 : 3.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		} else {
			if ( absDirection.z > absDirection.y )
				face = direction.z > 0.0 ? 2.0 : 5.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		}
		return face;
	}
	vec2 getUV( vec3 direction, float face ) {
		vec2 uv;
		if ( face == 0.0 ) {
			uv = vec2( direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 1.0 ) {
			uv = vec2( - direction.x, - direction.z ) / abs( direction.y );
		} else if ( face == 2.0 ) {
			uv = vec2( - direction.x, direction.y ) / abs( direction.z );
		} else if ( face == 3.0 ) {
			uv = vec2( - direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 4.0 ) {
			uv = vec2( - direction.x, direction.z ) / abs( direction.y );
		} else {
			uv = vec2( direction.x, direction.y ) / abs( direction.z );
		}
		return 0.5 * ( uv + 1.0 );
	}
	vec3 bilinearCubeUV( sampler2D envMap, vec3 direction, float mipInt ) {
		float face = getFace( direction );
		float filterInt = max( cubeUV_minMipLevel - mipInt, 0.0 );
		mipInt = max( mipInt, cubeUV_minMipLevel );
		float faceSize = exp2( mipInt );
		highp vec2 uv = getUV( direction, face ) * ( faceSize - 2.0 ) + 1.0;
		if ( face > 2.0 ) {
			uv.y += faceSize;
			face -= 3.0;
		}
		uv.x += face * faceSize;
		uv.x += filterInt * 3.0 * cubeUV_minTileSize;
		uv.y += 4.0 * ( exp2( CUBEUV_MAX_MIP ) - faceSize );
		uv.x *= CUBEUV_TEXEL_WIDTH;
		uv.y *= CUBEUV_TEXEL_HEIGHT;
		#ifdef texture2DGradEXT
			return texture2DGradEXT( envMap, uv, vec2( 0.0 ), vec2( 0.0 ) ).rgb;
		#else
			return texture2D( envMap, uv ).rgb;
		#endif
	}
	#define cubeUV_r0 1.0
	#define cubeUV_m0 - 2.0
	#define cubeUV_r1 0.8
	#define cubeUV_m1 - 1.0
	#define cubeUV_r4 0.4
	#define cubeUV_m4 2.0
	#define cubeUV_r5 0.305
	#define cubeUV_m5 3.0
	#define cubeUV_r6 0.21
	#define cubeUV_m6 4.0
	float roughnessToMip( float roughness ) {
		float mip = 0.0;
		if ( roughness >= cubeUV_r1 ) {
			mip = ( cubeUV_r0 - roughness ) * ( cubeUV_m1 - cubeUV_m0 ) / ( cubeUV_r0 - cubeUV_r1 ) + cubeUV_m0;
		} else if ( roughness >= cubeUV_r4 ) {
			mip = ( cubeUV_r1 - roughness ) * ( cubeUV_m4 - cubeUV_m1 ) / ( cubeUV_r1 - cubeUV_r4 ) + cubeUV_m1;
		} else if ( roughness >= cubeUV_r5 ) {
			mip = ( cubeUV_r4 - roughness ) * ( cubeUV_m5 - cubeUV_m4 ) / ( cubeUV_r4 - cubeUV_r5 ) + cubeUV_m4;
		} else if ( roughness >= cubeUV_r6 ) {
			mip = ( cubeUV_r5 - roughness ) * ( cubeUV_m6 - cubeUV_m5 ) / ( cubeUV_r5 - cubeUV_r6 ) + cubeUV_m5;
		} else {
			mip = - 2.0 * log2( 1.16 * roughness );		}
		return mip;
	}
	vec4 textureCubeUV( sampler2D envMap, vec3 sampleDir, float roughness ) {
		float mip = clamp( roughnessToMip( roughness ), cubeUV_m0, CUBEUV_MAX_MIP );
		float mipF = fract( mip );
		float mipInt = floor( mip );
		vec3 color0 = bilinearCubeUV( envMap, sampleDir, mipInt );
		if ( mipF == 0.0 ) {
			return vec4( color0, 1.0 );
		} else {
			vec3 color1 = bilinearCubeUV( envMap, sampleDir, mipInt + 1.0 );
			return vec4( mix( color0, color1, mipF ), 1.0 );
		}
	}
#endif`,dK=`vec3 transformedNormal = objectNormal;
#ifdef USE_TANGENT
	vec3 transformedTangent = objectTangent;
#endif
#ifdef USE_BATCHING
	mat3 bm = mat3( batchingMatrix );
	transformedNormal /= vec3( dot( bm[ 0 ], bm[ 0 ] ), dot( bm[ 1 ], bm[ 1 ] ), dot( bm[ 2 ], bm[ 2 ] ) );
	transformedNormal = bm * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = bm * transformedTangent;
	#endif
#endif
#ifdef USE_INSTANCING
	mat3 im = mat3( instanceMatrix );
	transformedNormal /= vec3( dot( im[ 0 ], im[ 0 ] ), dot( im[ 1 ], im[ 1 ] ), dot( im[ 2 ], im[ 2 ] ) );
	transformedNormal = im * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = im * transformedTangent;
	#endif
#endif
transformedNormal = normalMatrix * transformedNormal;
#ifdef FLIP_SIDED
	transformedNormal = - transformedNormal;
#endif
#ifdef USE_TANGENT
	transformedTangent = ( modelViewMatrix * vec4( transformedTangent, 0.0 ) ).xyz;
#endif`,lK=`#ifdef USE_DISPLACEMENTMAP
	uniform sampler2D displacementMap;
	uniform float displacementScale;
	uniform float displacementBias;
#endif`,uK=`#ifdef USE_DISPLACEMENTMAP
	transformed += normalize( objectNormal ) * ( texture2D( displacementMap, vDisplacementMapUv ).x * displacementScale + displacementBias );
#endif`,cK=`#ifdef USE_EMISSIVEMAP
	vec4 emissiveColor = texture2D( emissiveMap, vEmissiveMapUv );
	#ifdef DECODE_VIDEO_TEXTURE_EMISSIVE
		emissiveColor = sRGBTransferEOTF( emissiveColor );
	#endif
	totalEmissiveRadiance *= emissiveColor.rgb;
#endif`,nK=`#ifdef USE_EMISSIVEMAP
	uniform sampler2D emissiveMap;
#endif`,sK="gl_FragColor = linearToOutputTexel( gl_FragColor );",iK=`vec4 LinearTransferOETF( in vec4 value ) {
	return value;
}
vec4 sRGBTransferEOTF( in vec4 value ) {
	return vec4( mix( pow( value.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), value.rgb * 0.0773993808, vec3( lessThanEqual( value.rgb, vec3( 0.04045 ) ) ) ), value.a );
}
vec4 sRGBTransferOETF( in vec4 value ) {
	return vec4( mix( pow( value.rgb, vec3( 0.41666 ) ) * 1.055 - vec3( 0.055 ), value.rgb * 12.92, vec3( lessThanEqual( value.rgb, vec3( 0.0031308 ) ) ) ), value.a );
}`,oK=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vec3 cameraToFrag;
		if ( isOrthographic ) {
			cameraToFrag = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToFrag = normalize( vWorldPosition - cameraPosition );
		}
		vec3 worldNormal = transformNormalByInverseViewMatrix( normal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vec3 reflectVec = reflect( cameraToFrag, worldNormal );
		#else
			vec3 reflectVec = refract( cameraToFrag, worldNormal, refractionRatio );
		#endif
	#else
		vec3 reflectVec = vReflect;
	#endif
	#ifdef ENVMAP_TYPE_CUBE
		vec4 envColor = textureCube( envMap, envMapRotation * reflectVec );
		#ifdef ENVMAP_BLENDING_MULTIPLY
			outgoingLight = mix( outgoingLight, outgoingLight * envColor.xyz, specularStrength * reflectivity );
		#elif defined( ENVMAP_BLENDING_MIX )
			outgoingLight = mix( outgoingLight, envColor.xyz, specularStrength * reflectivity );
		#elif defined( ENVMAP_BLENDING_ADD )
			outgoingLight += envColor.xyz * specularStrength * reflectivity;
		#endif
	#endif
#endif`,aK=`#ifdef USE_ENVMAP
	uniform float envMapIntensity;
	uniform mat3 envMapRotation;
	#ifdef ENVMAP_TYPE_CUBE
		uniform samplerCube envMap;
	#else
		uniform sampler2D envMap;
	#endif
#endif`,rK=`#ifdef USE_ENVMAP
	uniform float reflectivity;
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		varying vec3 vWorldPosition;
		uniform float refractionRatio;
	#else
		varying vec3 vReflect;
	#endif
#endif`,tK=`#ifdef USE_ENVMAP
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		
		varying vec3 vWorldPosition;
	#else
		varying vec3 vReflect;
		uniform float refractionRatio;
	#endif
#endif`,eK=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vWorldPosition = worldPosition.xyz;
	#else
		vec3 cameraToVertex;
		if ( isOrthographic ) {
			cameraToVertex = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToVertex = normalize( worldPosition.xyz - cameraPosition );
		}
		vec3 worldNormal = transformNormalByInverseViewMatrix( transformedNormal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vReflect = reflect( cameraToVertex, worldNormal );
		#else
			vReflect = refract( cameraToVertex, worldNormal, refractionRatio );
		#endif
	#endif
#endif`,JH=`#ifdef USE_FOG
	vFogDepth = - mvPosition.z;
#endif`,QH=`#ifdef USE_FOG
	varying float vFogDepth;
#endif`,$H=`#ifdef USE_FOG
	#ifdef FOG_EXP2
		float fogFactor = 1.0 - exp( - fogDensity * fogDensity * vFogDepth * vFogDepth );
	#else
		float fogFactor = smoothstep( fogNear, fogFar, vFogDepth );
	#endif
	gl_FragColor.rgb = mix( gl_FragColor.rgb, fogColor, fogFactor );
#endif`,ZH=`#ifdef USE_FOG
	uniform vec3 fogColor;
	varying float vFogDepth;
	#ifdef FOG_EXP2
		uniform float fogDensity;
	#else
		uniform float fogNear;
		uniform float fogFar;
	#endif
#endif`,WH=`#ifdef USE_GRADIENTMAP
	uniform sampler2D gradientMap;
#endif
vec3 getGradientIrradiance( vec3 normal, vec3 lightDirection ) {
	float dotNL = dot( normal, lightDirection );
	vec2 coord = vec2( dotNL * 0.5 + 0.5, 0.0 );
	#ifdef USE_GRADIENTMAP
		return vec3( texture2D( gradientMap, coord ).r );
	#else
		vec2 fw = fwidth( coord ) * 0.5;
		return mix( vec3( 0.7 ), vec3( 1.0 ), smoothstep( 0.7 - fw.x, 0.7 + fw.x, coord.x ) );
	#endif
}`,KH=`#ifdef USE_LIGHTMAP
	uniform sampler2D lightMap;
	uniform float lightMapIntensity;
#endif`,HH=`LambertMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularStrength = specularStrength;`,YH=`varying vec3 vViewPosition;
struct LambertMaterial {
	vec3 diffuseColor;
	float specularStrength;
};
void RE_Direct_Lambert( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Lambert( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Lambert
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Lambert`,XH=`uniform bool receiveShadow;
uniform vec3 ambientLightColor;
#if defined( USE_LIGHT_PROBES )
	uniform vec3 lightProbe[ 9 ];
#endif
vec3 shGetIrradianceAt( in vec3 normal, in vec3 shCoefficients[ 9 ] ) {
	float x = normal.x, y = normal.y, z = normal.z;
	vec3 result = shCoefficients[ 0 ] * 0.886227;
	result += shCoefficients[ 1 ] * 2.0 * 0.511664 * y;
	result += shCoefficients[ 2 ] * 2.0 * 0.511664 * z;
	result += shCoefficients[ 3 ] * 2.0 * 0.511664 * x;
	result += shCoefficients[ 4 ] * 2.0 * 0.429043 * x * y;
	result += shCoefficients[ 5 ] * 2.0 * 0.429043 * y * z;
	result += shCoefficients[ 6 ] * ( 0.743125 * z * z - 0.247708 );
	result += shCoefficients[ 7 ] * 2.0 * 0.429043 * x * z;
	result += shCoefficients[ 8 ] * 0.429043 * ( x * x - y * y );
	return result;
}
vec3 getLightProbeIrradiance( const in vec3 lightProbe[ 9 ], const in vec3 normal ) {
	vec3 worldNormal = transformNormalByInverseViewMatrix( normal, viewMatrix );
	vec3 irradiance = shGetIrradianceAt( worldNormal, lightProbe );
	return irradiance;
}
vec3 getAmbientLightIrradiance( const in vec3 ambientLightColor ) {
	vec3 irradiance = ambientLightColor;
	return irradiance;
}
float getDistanceAttenuation( const in float lightDistance, const in float cutoffDistance, const in float decayExponent ) {
	float distanceFalloff = 1.0 / max( pow( lightDistance, decayExponent ), 0.01 );
	if ( cutoffDistance > 0.0 ) {
		distanceFalloff *= pow2( saturate( 1.0 - pow4( lightDistance / cutoffDistance ) ) );
	}
	return distanceFalloff;
}
float getSpotAttenuation( const in float coneCosine, const in float penumbraCosine, const in float angleCosine ) {
	return smoothstep( coneCosine, penumbraCosine, angleCosine );
}
#if NUM_DIR_LIGHTS > 0
	struct DirectionalLight {
		vec3 direction;
		vec3 color;
	};
	uniform DirectionalLight directionalLights[ NUM_DIR_LIGHTS ];
	void getDirectionalLightInfo( const in DirectionalLight directionalLight, out IncidentLight light ) {
		light.color = directionalLight.color;
		light.direction = directionalLight.direction;
		light.visible = true;
	}
#endif
#if NUM_POINT_LIGHTS > 0
	struct PointLight {
		vec3 position;
		vec3 color;
		float distance;
		float decay;
	};
	uniform PointLight pointLights[ NUM_POINT_LIGHTS ];
	void getPointLightInfo( const in PointLight pointLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = pointLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float lightDistance = length( lVector );
		light.color = pointLight.color;
		light.color *= getDistanceAttenuation( lightDistance, pointLight.distance, pointLight.decay );
		light.visible = ( light.color != vec3( 0.0 ) );
	}
#endif
#if NUM_SPOT_LIGHTS > 0
	struct SpotLight {
		vec3 position;
		vec3 direction;
		vec3 color;
		float distance;
		float decay;
		float coneCos;
		float penumbraCos;
	};
	uniform SpotLight spotLights[ NUM_SPOT_LIGHTS ];
	void getSpotLightInfo( const in SpotLight spotLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = spotLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float angleCos = dot( light.direction, spotLight.direction );
		float spotAttenuation = getSpotAttenuation( spotLight.coneCos, spotLight.penumbraCos, angleCos );
		if ( spotAttenuation > 0.0 ) {
			float lightDistance = length( lVector );
			light.color = spotLight.color * spotAttenuation;
			light.color *= getDistanceAttenuation( lightDistance, spotLight.distance, spotLight.decay );
			light.visible = ( light.color != vec3( 0.0 ) );
		} else {
			light.color = vec3( 0.0 );
			light.visible = false;
		}
	}
#endif
#if NUM_RECT_AREA_LIGHTS > 0
	struct RectAreaLight {
		vec3 color;
		vec3 position;
		vec3 halfWidth;
		vec3 halfHeight;
	};
	uniform sampler2D ltc_1;	uniform sampler2D ltc_2;
	uniform RectAreaLight rectAreaLights[ NUM_RECT_AREA_LIGHTS ];
#endif
#if NUM_HEMI_LIGHTS > 0
	struct HemisphereLight {
		vec3 direction;
		vec3 skyColor;
		vec3 groundColor;
	};
	uniform HemisphereLight hemisphereLights[ NUM_HEMI_LIGHTS ];
	vec3 getHemisphereLightIrradiance( const in HemisphereLight hemiLight, const in vec3 normal ) {
		float dotNL = dot( normal, hemiLight.direction );
		float hemiDiffuseWeight = 0.5 * dotNL + 0.5;
		vec3 irradiance = mix( hemiLight.groundColor, hemiLight.skyColor, hemiDiffuseWeight );
		return irradiance;
	}
#endif
#include <lightprobes_pars_fragment>`,UH=`#ifdef USE_ENVMAP
	vec3 getIBLIrradiance( const in vec3 normal ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 worldNormal = transformNormalByInverseViewMatrix( normal, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * worldNormal, 1.0 );
			return PI * envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	vec3 getIBLRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 reflectVec = reflect( - viewDir, normal );
			reflectVec = normalize( mix( reflectVec, normal, pow4( roughness ) ) );
			reflectVec = transformDirectionByInverseViewMatrix( reflectVec, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * reflectVec, roughness );
			return envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	#ifdef USE_ANISOTROPY
		vec3 getIBLAnisotropyRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness, const in vec3 bitangent, const in float anisotropy ) {
			#ifdef ENVMAP_TYPE_CUBE_UV
				vec3 bentNormal = cross( bitangent, viewDir );
				bentNormal = normalize( cross( bentNormal, bitangent ) );
				bentNormal = normalize( mix( bentNormal, normal, pow2( pow2( 1.0 - anisotropy * ( 1.0 - roughness ) ) ) ) );
				return getIBLRadiance( viewDir, bentNormal, roughness );
			#else
				return vec3( 0.0 );
			#endif
		}
	#endif
#endif`,GH=`ToonMaterial material;
material.diffuseColor = diffuseColor.rgb;`,EH=`varying vec3 vViewPosition;
struct ToonMaterial {
	vec3 diffuseColor;
};
void RE_Direct_Toon( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	vec3 irradiance = getGradientIrradiance( geometryNormal, directLight.direction ) * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Toon( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Toon
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Toon`,NH=`BlinnPhongMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularColor = specular;
material.specularShininess = shininess;
material.specularStrength = specularStrength;`,qH=`varying vec3 vViewPosition;
struct BlinnPhongMaterial {
	vec3 diffuseColor;
	vec3 specularColor;
	float specularShininess;
	float specularStrength;
};
void RE_Direct_BlinnPhong( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
	reflectedLight.directSpecular += irradiance * BRDF_BlinnPhong( directLight.direction, geometryViewDir, geometryNormal, material.specularColor, material.specularShininess ) * material.specularStrength;
}
void RE_IndirectDiffuse_BlinnPhong( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_BlinnPhong
#define RE_IndirectDiffuse		RE_IndirectDiffuse_BlinnPhong`,FH=`PhysicalMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.diffuseContribution = diffuseColor.rgb * ( 1.0 - metalnessFactor );
material.metalness = metalnessFactor;
vec3 dxy = max( abs( dFdx( nonPerturbedNormal ) ), abs( dFdy( nonPerturbedNormal ) ) );
float geometryRoughness = max( max( dxy.x, dxy.y ), dxy.z );
material.roughness = max( roughnessFactor, 0.0525 );material.roughness += geometryRoughness;
material.roughness = min( material.roughness, 1.0 );
#ifdef IOR
	material.ior = ior;
	#ifdef USE_SPECULAR
		float specularIntensityFactor = specularIntensity;
		vec3 specularColorFactor = specularColor;
		#ifdef USE_SPECULAR_COLORMAP
			specularColorFactor *= texture2D( specularColorMap, vSpecularColorMapUv ).rgb;
		#endif
		#ifdef USE_SPECULAR_INTENSITYMAP
			specularIntensityFactor *= texture2D( specularIntensityMap, vSpecularIntensityMapUv ).a;
		#endif
		material.specularF90 = mix( specularIntensityFactor, 1.0, metalnessFactor );
	#else
		float specularIntensityFactor = 1.0;
		vec3 specularColorFactor = vec3( 1.0 );
		material.specularF90 = 1.0;
	#endif
	material.specularColor = min( pow2( ( material.ior - 1.0 ) / ( material.ior + 1.0 ) ) * specularColorFactor, vec3( 1.0 ) ) * specularIntensityFactor;
	material.specularColorBlended = mix( material.specularColor, diffuseColor.rgb, metalnessFactor );
#else
	material.specularColor = vec3( 0.04 );
	material.specularColorBlended = mix( material.specularColor, diffuseColor.rgb, metalnessFactor );
	material.specularF90 = 1.0;
#endif
#ifdef USE_CLEARCOAT
	material.clearcoat = clearcoat;
	material.clearcoatRoughness = clearcoatRoughness;
	material.clearcoatF0 = vec3( 0.04 );
	material.clearcoatF90 = 1.0;
	#ifdef USE_CLEARCOATMAP
		material.clearcoat *= texture2D( clearcoatMap, vClearcoatMapUv ).x;
	#endif
	#ifdef USE_CLEARCOAT_ROUGHNESSMAP
		material.clearcoatRoughness *= texture2D( clearcoatRoughnessMap, vClearcoatRoughnessMapUv ).y;
	#endif
	material.clearcoat = saturate( material.clearcoat );	material.clearcoatRoughness = max( material.clearcoatRoughness, 0.0525 );
	material.clearcoatRoughness += geometryRoughness;
	material.clearcoatRoughness = min( material.clearcoatRoughness, 1.0 );
#endif
#ifdef USE_DISPERSION
	material.dispersion = dispersion;
#endif
#ifdef USE_IRIDESCENCE
	material.iridescence = iridescence;
	material.iridescenceIOR = iridescenceIOR;
	#ifdef USE_IRIDESCENCEMAP
		material.iridescence *= texture2D( iridescenceMap, vIridescenceMapUv ).r;
	#endif
	#ifdef USE_IRIDESCENCE_THICKNESSMAP
		material.iridescenceThickness = (iridescenceThicknessMaximum - iridescenceThicknessMinimum) * texture2D( iridescenceThicknessMap, vIridescenceThicknessMapUv ).g + iridescenceThicknessMinimum;
	#else
		material.iridescenceThickness = iridescenceThicknessMaximum;
	#endif
#endif
#ifdef USE_SHEEN
	material.sheenColor = sheenColor;
	#ifdef USE_SHEEN_COLORMAP
		material.sheenColor *= texture2D( sheenColorMap, vSheenColorMapUv ).rgb;
	#endif
	material.sheenRoughness = clamp( sheenRoughness, 0.0001, 1.0 );
	#ifdef USE_SHEEN_ROUGHNESSMAP
		material.sheenRoughness *= texture2D( sheenRoughnessMap, vSheenRoughnessMapUv ).a;
	#endif
#endif
#ifdef USE_ANISOTROPY
	#ifdef USE_ANISOTROPYMAP
		mat2 anisotropyMat = mat2( anisotropyVector.x, anisotropyVector.y, - anisotropyVector.y, anisotropyVector.x );
		vec3 anisotropyPolar = texture2D( anisotropyMap, vAnisotropyMapUv ).rgb;
		vec2 anisotropyV = anisotropyMat * normalize( 2.0 * anisotropyPolar.rg - vec2( 1.0 ) ) * anisotropyPolar.b;
	#else
		vec2 anisotropyV = anisotropyVector;
	#endif
	material.anisotropy = length( anisotropyV );
	if( material.anisotropy == 0.0 ) {
		anisotropyV = vec2( 1.0, 0.0 );
	} else {
		anisotropyV /= material.anisotropy;
		material.anisotropy = saturate( material.anisotropy );
	}
	material.alphaT = mix( pow2( material.roughness ), 1.0, pow2( material.anisotropy ) );
	material.anisotropyT = tbn[ 0 ] * anisotropyV.x + tbn[ 1 ] * anisotropyV.y;
	material.anisotropyB = tbn[ 1 ] * anisotropyV.x - tbn[ 0 ] * anisotropyV.y;
#endif`,DH=`uniform sampler2D dfgLUT;
struct PhysicalMaterial {
	vec3 diffuseColor;
	vec3 diffuseContribution;
	vec3 specularColor;
	vec3 specularColorBlended;
	float roughness;
	float metalness;
	float specularF90;
	float dispersion;
	#ifdef USE_CLEARCOAT
		float clearcoat;
		float clearcoatRoughness;
		vec3 clearcoatF0;
		float clearcoatF90;
	#endif
	#ifdef USE_IRIDESCENCE
		float iridescence;
		float iridescenceIOR;
		float iridescenceThickness;
		vec3 iridescenceFresnel;
		vec3 iridescenceF0;
		vec3 iridescenceFresnelDielectric;
		vec3 iridescenceFresnelMetallic;
	#endif
	#ifdef USE_SHEEN
		vec3 sheenColor;
		float sheenRoughness;
	#endif
	#ifdef IOR
		float ior;
	#endif
	#ifdef USE_TRANSMISSION
		float transmission;
		float transmissionAlpha;
		float thickness;
		float attenuationDistance;
		vec3 attenuationColor;
	#endif
	#ifdef USE_ANISOTROPY
		float anisotropy;
		float alphaT;
		vec3 anisotropyT;
		vec3 anisotropyB;
	#endif
};
vec3 clearcoatSpecularDirect = vec3( 0.0 );
vec3 clearcoatSpecularIndirect = vec3( 0.0 );
vec3 sheenSpecularDirect = vec3( 0.0 );
vec3 sheenSpecularIndirect = vec3(0.0 );
vec3 Schlick_to_F0( const in vec3 f, const in float f90, const in float dotVH ) {
    float x = clamp( 1.0 - dotVH, 0.0, 1.0 );
    float x2 = x * x;
    float x5 = clamp( x * x2 * x2, 0.0, 0.9999 );
    return ( f - vec3( f90 ) * x5 ) / ( 1.0 - x5 );
}
float V_GGX_SmithCorrelated( const in float alpha, const in float dotNL, const in float dotNV ) {
	float a2 = pow2( alpha );
	float gv = dotNL * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNV ) );
	float gl = dotNV * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNL ) );
	return 0.5 / max( gv + gl, EPSILON );
}
float D_GGX( const in float alpha, const in float dotNH ) {
	float a2 = pow2( alpha );
	float denom = pow2( dotNH ) * ( a2 - 1.0 ) + 1.0;
	return RECIPROCAL_PI * a2 / pow2( denom );
}
#ifdef USE_ANISOTROPY
	float V_GGX_SmithCorrelated_Anisotropic( const in float alphaT, const in float alphaB, const in float dotTV, const in float dotBV, const in float dotTL, const in float dotBL, const in float dotNV, const in float dotNL ) {
		float gv = dotNL * length( vec3( alphaT * dotTV, alphaB * dotBV, dotNV ) );
		float gl = dotNV * length( vec3( alphaT * dotTL, alphaB * dotBL, dotNL ) );
		return 0.5 / max( gv + gl, EPSILON );
	}
	float D_GGX_Anisotropic( const in float alphaT, const in float alphaB, const in float dotNH, const in float dotTH, const in float dotBH ) {
		float a2 = alphaT * alphaB;
		highp vec3 v = vec3( alphaB * dotTH, alphaT * dotBH, a2 * dotNH );
		highp float v2 = dot( v, v );
		float w2 = a2 / v2;
		return RECIPROCAL_PI * a2 * pow2 ( w2 );
	}
#endif
#ifdef USE_CLEARCOAT
	vec3 BRDF_GGX_Clearcoat( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material) {
		vec3 f0 = material.clearcoatF0;
		float f90 = material.clearcoatF90;
		float roughness = material.clearcoatRoughness;
		float alpha = pow2( roughness );
		vec3 halfDir = normalize( lightDir + viewDir );
		float dotNL = saturate( dot( normal, lightDir ) );
		float dotNV = saturate( dot( normal, viewDir ) );
		float dotNH = saturate( dot( normal, halfDir ) );
		float dotVH = saturate( dot( viewDir, halfDir ) );
		vec3 F = F_Schlick( f0, f90, dotVH );
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
		return F * ( V * D );
	}
#endif
vec3 BRDF_GGX( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material ) {
	vec3 f0 = material.specularColorBlended;
	float f90 = material.specularF90;
	float roughness = material.roughness;
	float alpha = pow2( roughness );
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( f0, f90, dotVH );
	#ifdef USE_IRIDESCENCE
		F = mix( F, material.iridescenceFresnel, material.iridescence );
	#endif
	#ifdef USE_ANISOTROPY
		float dotTL = dot( material.anisotropyT, lightDir );
		float dotTV = dot( material.anisotropyT, viewDir );
		float dotTH = dot( material.anisotropyT, halfDir );
		float dotBL = dot( material.anisotropyB, lightDir );
		float dotBV = dot( material.anisotropyB, viewDir );
		float dotBH = dot( material.anisotropyB, halfDir );
		float V = V_GGX_SmithCorrelated_Anisotropic( material.alphaT, alpha, dotTV, dotBV, dotTL, dotBL, dotNV, dotNL );
		float D = D_GGX_Anisotropic( material.alphaT, alpha, dotNH, dotTH, dotBH );
	#else
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
	#endif
	return F * ( V * D );
}
vec2 LTC_Uv( const in vec3 N, const in vec3 V, const in float roughness ) {
	const float LUT_SIZE = 64.0;
	const float LUT_SCALE = ( LUT_SIZE - 1.0 ) / LUT_SIZE;
	const float LUT_BIAS = 0.5 / LUT_SIZE;
	float dotNV = saturate( dot( N, V ) );
	vec2 uv = vec2( roughness, sqrt( 1.0 - dotNV ) );
	uv = uv * LUT_SCALE + LUT_BIAS;
	return uv;
}
float LTC_ClippedSphereFormFactor( const in vec3 f ) {
	float l = length( f );
	return max( ( l * l + f.z ) / ( l + 1.0 ), 0.0 );
}
vec3 LTC_EdgeVectorFormFactor( const in vec3 v1, const in vec3 v2 ) {
	float x = dot( v1, v2 );
	float y = abs( x );
	float a = 0.8543985 + ( 0.4965155 + 0.0145206 * y ) * y;
	float b = 3.4175940 + ( 4.1616724 + y ) * y;
	float v = a / b;
	float theta_sintheta = ( x > 0.0 ) ? v : 0.5 * inversesqrt( max( 1.0 - x * x, 1e-7 ) ) - v;
	return cross( v1, v2 ) * theta_sintheta;
}
vec3 LTC_Evaluate( const in vec3 N, const in vec3 V, const in vec3 P, const in mat3 mInv, const in vec3 rectCoords[ 4 ] ) {
	vec3 v1 = rectCoords[ 1 ] - rectCoords[ 0 ];
	vec3 v2 = rectCoords[ 3 ] - rectCoords[ 0 ];
	vec3 lightNormal = cross( v1, v2 );
	if( dot( lightNormal, P - rectCoords[ 0 ] ) < 0.0 ) return vec3( 0.0 );
	vec3 T1, T2;
	T1 = normalize( V - N * dot( V, N ) );
	T2 = - cross( N, T1 );
	mat3 mat = mInv * transpose( mat3( T1, T2, N ) );
	vec3 coords[ 4 ];
	coords[ 0 ] = mat * ( rectCoords[ 0 ] - P );
	coords[ 1 ] = mat * ( rectCoords[ 1 ] - P );
	coords[ 2 ] = mat * ( rectCoords[ 2 ] - P );
	coords[ 3 ] = mat * ( rectCoords[ 3 ] - P );
	coords[ 0 ] = normalize( coords[ 0 ] );
	coords[ 1 ] = normalize( coords[ 1 ] );
	coords[ 2 ] = normalize( coords[ 2 ] );
	coords[ 3 ] = normalize( coords[ 3 ] );
	vec3 vectorFormFactor = vec3( 0.0 );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 0 ], coords[ 1 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 1 ], coords[ 2 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 2 ], coords[ 3 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 3 ], coords[ 0 ] );
	float result = LTC_ClippedSphereFormFactor( vectorFormFactor );
	return vec3( result );
}
#if defined( USE_SHEEN )
float D_Charlie( float roughness, float dotNH ) {
	float alpha = pow2( roughness );
	float invAlpha = 1.0 / alpha;
	float cos2h = dotNH * dotNH;
	float sin2h = max( 1.0 - cos2h, 0.0078125 );
	return ( 2.0 + invAlpha ) * pow( sin2h, invAlpha * 0.5 ) / ( 2.0 * PI );
}
float V_Neubelt( float dotNV, float dotNL ) {
	return saturate( 1.0 / ( 4.0 * ( dotNL + dotNV - dotNL * dotNV ) ) );
}
vec3 BRDF_Sheen( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, vec3 sheenColor, const in float sheenRoughness ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float D = D_Charlie( sheenRoughness, dotNH );
	float V = V_Neubelt( dotNV, dotNL );
	return sheenColor * ( D * V );
}
#endif
float IBLSheenBRDF( const in vec3 normal, const in vec3 viewDir, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	float r2 = roughness * roughness;
	float rInv = 1.0 / ( roughness + 0.1 );
	float a = -1.9362 + 1.0678 * roughness + 0.4573 * r2 - 0.8469 * rInv;
	float b = -0.6014 + 0.5538 * roughness - 0.4670 * r2 - 0.1255 * rInv;
	float DG = exp( a * dotNV + b );
	return saturate( DG );
}
vec3 EnvironmentBRDF( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	vec2 fab = texture2D( dfgLUT, vec2( roughness, dotNV ) ).rg;
	return specularColor * fab.x + specularF90 * fab.y;
}
#ifdef USE_IRIDESCENCE
void computeMultiscatteringIridescence( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float iridescence, const in vec3 iridescenceF0, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#else
void computeMultiscattering( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#endif
	float dotNV = saturate( dot( normal, viewDir ) );
	vec2 fab = texture2D( dfgLUT, vec2( roughness, dotNV ) ).rg;
	#ifdef USE_IRIDESCENCE
		vec3 Fr = mix( specularColor, iridescenceF0, iridescence );
	#else
		vec3 Fr = specularColor;
	#endif
	vec3 FssEss = Fr * fab.x + specularF90 * fab.y;
	float Ess = fab.x + fab.y;
	float Ems = 1.0 - Ess;
	vec3 Favg = Fr + ( 1.0 - Fr ) * 0.047619;	vec3 Fms = FssEss * Favg / ( 1.0 - Ems * Favg );
	singleScatter += FssEss;
	multiScatter += Fms * Ems;
}
vec3 BRDF_GGX_Multiscatter( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material ) {
	vec3 singleScatter = BRDF_GGX( lightDir, viewDir, normal, material );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	vec2 dfgV = texture2D( dfgLUT, vec2( material.roughness, dotNV ) ).rg;
	vec2 dfgL = texture2D( dfgLUT, vec2( material.roughness, dotNL ) ).rg;
	vec3 FssEss_V = material.specularColorBlended * dfgV.x + material.specularF90 * dfgV.y;
	vec3 FssEss_L = material.specularColorBlended * dfgL.x + material.specularF90 * dfgL.y;
	float Ess_V = dfgV.x + dfgV.y;
	float Ess_L = dfgL.x + dfgL.y;
	float Ems_V = 1.0 - Ess_V;
	float Ems_L = 1.0 - Ess_L;
	vec3 Favg = material.specularColorBlended + ( 1.0 - material.specularColorBlended ) * 0.047619;
	vec3 Fms = FssEss_V * FssEss_L * Favg / ( 1.0 - Ems_V * Ems_L * Favg + EPSILON );
	float compensationFactor = Ems_V * Ems_L;
	vec3 multiScatter = Fms * compensationFactor;
	return singleScatter + multiScatter;
}
#if NUM_RECT_AREA_LIGHTS > 0
	void RE_Direct_RectArea_Physical( const in RectAreaLight rectAreaLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
		vec3 normal = geometryNormal;
		vec3 viewDir = geometryViewDir;
		vec3 position = geometryPosition;
		vec3 lightPos = rectAreaLight.position;
		vec3 halfWidth = rectAreaLight.halfWidth;
		vec3 halfHeight = rectAreaLight.halfHeight;
		vec3 lightColor = rectAreaLight.color;
		float roughness = material.roughness;
		vec3 rectCoords[ 4 ];
		rectCoords[ 0 ] = lightPos + halfWidth - halfHeight;		rectCoords[ 1 ] = lightPos - halfWidth - halfHeight;
		rectCoords[ 2 ] = lightPos - halfWidth + halfHeight;
		rectCoords[ 3 ] = lightPos + halfWidth + halfHeight;
		vec2 uv = LTC_Uv( normal, viewDir, roughness );
		vec4 t1 = texture2D( ltc_1, uv );
		vec4 t2 = texture2D( ltc_2, uv );
		mat3 mInv = mat3(
			vec3( t1.x, 0, t1.y ),
			vec3(    0, 1,    0 ),
			vec3( t1.z, 0, t1.w )
		);
		vec3 fresnel = ( material.specularColorBlended * t2.x + ( material.specularF90 - material.specularColorBlended ) * t2.y );
		reflectedLight.directSpecular += lightColor * fresnel * LTC_Evaluate( normal, viewDir, position, mInv, rectCoords );
		reflectedLight.directDiffuse += lightColor * material.diffuseContribution * LTC_Evaluate( normal, viewDir, position, mat3( 1.0 ), rectCoords );
		#ifdef USE_CLEARCOAT
			vec3 Ncc = geometryClearcoatNormal;
			vec2 uvClearcoat = LTC_Uv( Ncc, viewDir, material.clearcoatRoughness );
			vec4 t1Clearcoat = texture2D( ltc_1, uvClearcoat );
			vec4 t2Clearcoat = texture2D( ltc_2, uvClearcoat );
			mat3 mInvClearcoat = mat3(
				vec3( t1Clearcoat.x, 0, t1Clearcoat.y ),
				vec3(             0, 1,             0 ),
				vec3( t1Clearcoat.z, 0, t1Clearcoat.w )
			);
			vec3 fresnelClearcoat = material.clearcoatF0 * t2Clearcoat.x + ( material.clearcoatF90 - material.clearcoatF0 ) * t2Clearcoat.y;
			clearcoatSpecularDirect += lightColor * fresnelClearcoat * LTC_Evaluate( Ncc, viewDir, position, mInvClearcoat, rectCoords );
		#endif
	}
#endif
void RE_Direct_Physical( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	#ifdef USE_CLEARCOAT
		float dotNLcc = saturate( dot( geometryClearcoatNormal, directLight.direction ) );
		vec3 ccIrradiance = dotNLcc * directLight.color;
		clearcoatSpecularDirect += ccIrradiance * BRDF_GGX_Clearcoat( directLight.direction, geometryViewDir, geometryClearcoatNormal, material );
	#endif
	#ifdef USE_SHEEN
 
 		sheenSpecularDirect += irradiance * BRDF_Sheen( directLight.direction, geometryViewDir, geometryNormal, material.sheenColor, material.sheenRoughness );
 
 		float sheenAlbedoV = IBLSheenBRDF( geometryNormal, geometryViewDir, material.sheenRoughness );
 		float sheenAlbedoL = IBLSheenBRDF( geometryNormal, directLight.direction, material.sheenRoughness );
 
 		float sheenEnergyComp = 1.0 - max3( material.sheenColor ) * max( sheenAlbedoV, sheenAlbedoL );
 
 		irradiance *= sheenEnergyComp;
 
 	#endif
	reflectedLight.directSpecular += irradiance * BRDF_GGX_Multiscatter( directLight.direction, geometryViewDir, geometryNormal, material );
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseContribution );
}
void RE_IndirectDiffuse_Physical( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	vec3 diffuse = irradiance * BRDF_Lambert( material.diffuseContribution );
	#ifdef USE_SHEEN
		float sheenAlbedo = IBLSheenBRDF( geometryNormal, geometryViewDir, material.sheenRoughness );
		float sheenEnergyComp = 1.0 - max3( material.sheenColor ) * sheenAlbedo;
		diffuse *= sheenEnergyComp;
	#endif
	reflectedLight.indirectDiffuse += diffuse;
}
void RE_IndirectSpecular_Physical( const in vec3 radiance, const in vec3 irradiance, const in vec3 clearcoatRadiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight) {
	#ifdef USE_CLEARCOAT
		clearcoatSpecularIndirect += clearcoatRadiance * EnvironmentBRDF( geometryClearcoatNormal, geometryViewDir, material.clearcoatF0, material.clearcoatF90, material.clearcoatRoughness );
	#endif
	#ifdef USE_SHEEN
		sheenSpecularIndirect += irradiance * material.sheenColor * IBLSheenBRDF( geometryNormal, geometryViewDir, material.sheenRoughness ) * RECIPROCAL_PI;
 	#endif
	vec3 singleScatteringDielectric = vec3( 0.0 );
	vec3 multiScatteringDielectric = vec3( 0.0 );
	vec3 singleScatteringMetallic = vec3( 0.0 );
	vec3 multiScatteringMetallic = vec3( 0.0 );
	#ifdef USE_IRIDESCENCE
		computeMultiscatteringIridescence( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.iridescence, material.iridescenceFresnelDielectric, material.roughness, singleScatteringDielectric, multiScatteringDielectric );
		computeMultiscatteringIridescence( geometryNormal, geometryViewDir, material.diffuseColor, material.specularF90, material.iridescence, material.iridescenceFresnelMetallic, material.roughness, singleScatteringMetallic, multiScatteringMetallic );
	#else
		computeMultiscattering( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.roughness, singleScatteringDielectric, multiScatteringDielectric );
		computeMultiscattering( geometryNormal, geometryViewDir, material.diffuseColor, material.specularF90, material.roughness, singleScatteringMetallic, multiScatteringMetallic );
	#endif
	vec3 singleScattering = mix( singleScatteringDielectric, singleScatteringMetallic, material.metalness );
	vec3 multiScattering = mix( multiScatteringDielectric, multiScatteringMetallic, material.metalness );
	vec3 totalScatteringDielectric = singleScatteringDielectric + multiScatteringDielectric;
	vec3 diffuse = material.diffuseContribution * ( 1.0 - totalScatteringDielectric );
	vec3 cosineWeightedIrradiance = irradiance * RECIPROCAL_PI;
	vec3 indirectSpecular = radiance * singleScattering;
	indirectSpecular += multiScattering * cosineWeightedIrradiance;
	vec3 indirectDiffuse = diffuse * cosineWeightedIrradiance;
	#ifdef USE_SHEEN
		float sheenAlbedo = IBLSheenBRDF( geometryNormal, geometryViewDir, material.sheenRoughness );
		float sheenEnergyComp = 1.0 - max3( material.sheenColor ) * sheenAlbedo;
		indirectSpecular *= sheenEnergyComp;
		indirectDiffuse *= sheenEnergyComp;
	#endif
	reflectedLight.indirectSpecular += indirectSpecular;
	reflectedLight.indirectDiffuse += indirectDiffuse;
}
#define RE_Direct				RE_Direct_Physical
#define RE_Direct_RectArea		RE_Direct_RectArea_Physical
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Physical
#define RE_IndirectSpecular		RE_IndirectSpecular_Physical
float computeSpecularOcclusion( const in float dotNV, const in float ambientOcclusion, const in float roughness ) {
	return saturate( pow( dotNV + ambientOcclusion, exp2( - 16.0 * roughness - 1.0 ) ) - 1.0 + ambientOcclusion );
}`,RH=`
vec3 geometryPosition = - vViewPosition;
vec3 geometryNormal = normal;
vec3 geometryViewDir = ( isOrthographic ) ? vec3( 0, 0, 1 ) : normalize( vViewPosition );
vec3 geometryClearcoatNormal = vec3( 0.0 );
#ifdef USE_CLEARCOAT
	geometryClearcoatNormal = clearcoatNormal;
#endif
#ifdef USE_IRIDESCENCE
	float dotNVi = saturate( dot( normal, geometryViewDir ) );
	if ( material.iridescenceThickness == 0.0 ) {
		material.iridescence = 0.0;
	} else {
		material.iridescence = saturate( material.iridescence );
	}
	if ( material.iridescence > 0.0 ) {
		material.iridescenceFresnelDielectric = evalIridescence( 1.0, material.iridescenceIOR, dotNVi, material.iridescenceThickness, material.specularColor );
		material.iridescenceFresnelMetallic = evalIridescence( 1.0, material.iridescenceIOR, dotNVi, material.iridescenceThickness, material.diffuseColor );
		material.iridescenceFresnel = mix( material.iridescenceFresnelDielectric, material.iridescenceFresnelMetallic, material.metalness );
		material.iridescenceF0 = Schlick_to_F0( material.iridescenceFresnel, 1.0, dotNVi );
	}
#endif
IncidentLight directLight;
#if ( NUM_POINT_LIGHTS > 0 ) && defined( RE_Direct )
	PointLight pointLight;
	#if defined( USE_SHADOWMAP ) && NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHTS; i ++ ) {
		pointLight = pointLights[ i ];
		getPointLightInfo( pointLight, geometryPosition, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_POINT_LIGHT_SHADOWS ) && ( defined( SHADOWMAP_TYPE_PCF ) || defined( SHADOWMAP_TYPE_BASIC ) )
		pointLightShadow = pointLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getPointShadow( pointShadowMap[ i ], pointLightShadow.shadowMapSize, pointLightShadow.shadowIntensity, pointLightShadow.shadowBias, pointLightShadow.shadowRadius, vPointShadowCoord[ i ], pointLightShadow.shadowCameraNear, pointLightShadow.shadowCameraFar ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_SPOT_LIGHTS > 0 ) && defined( RE_Direct )
	SpotLight spotLight;
	vec4 spotColor;
	vec3 spotLightCoord;
	bool inSpotLightMap;
	#if defined( USE_SHADOWMAP ) && NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHTS; i ++ ) {
		spotLight = spotLights[ i ];
		getSpotLightInfo( spotLight, geometryPosition, directLight );
		#if ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#define SPOT_LIGHT_MAP_INDEX UNROLLED_LOOP_INDEX
		#elif ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		#define SPOT_LIGHT_MAP_INDEX NUM_SPOT_LIGHT_MAPS
		#else
		#define SPOT_LIGHT_MAP_INDEX ( UNROLLED_LOOP_INDEX - NUM_SPOT_LIGHT_SHADOWS + NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#endif
		#if ( SPOT_LIGHT_MAP_INDEX < NUM_SPOT_LIGHT_MAPS )
			spotLightCoord = vSpotLightCoord[ i ].xyz / vSpotLightCoord[ i ].w;
			inSpotLightMap = all( lessThan( abs( spotLightCoord * 2. - 1. ), vec3( 1.0 ) ) );
			spotColor = texture2D( spotLightMap[ SPOT_LIGHT_MAP_INDEX ], spotLightCoord.xy );
			directLight.color = inSpotLightMap ? directLight.color * spotColor.rgb : directLight.color;
		#endif
		#undef SPOT_LIGHT_MAP_INDEX
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		spotLightShadow = spotLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( spotShadowMap[ i ], spotLightShadow.shadowMapSize, spotLightShadow.shadowIntensity, spotLightShadow.shadowBias, spotLightShadow.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_DIR_LIGHTS > 0 ) && defined( RE_Direct )
	DirectionalLight directionalLight;
	#if defined( USE_SHADOWMAP ) && NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHTS; i ++ ) {
		directionalLight = directionalLights[ i ];
		getDirectionalLightInfo( directionalLight, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_DIR_LIGHT_SHADOWS )
		directionalLightShadow = directionalLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( directionalShadowMap[ i ], directionalLightShadow.shadowMapSize, directionalLightShadow.shadowIntensity, directionalLightShadow.shadowBias, directionalLightShadow.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_RECT_AREA_LIGHTS > 0 ) && defined( RE_Direct_RectArea )
	RectAreaLight rectAreaLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_RECT_AREA_LIGHTS; i ++ ) {
		rectAreaLight = rectAreaLights[ i ];
		RE_Direct_RectArea( rectAreaLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if defined( RE_IndirectDiffuse )
	vec3 iblIrradiance = vec3( 0.0 );
	vec3 irradiance = getAmbientLightIrradiance( ambientLightColor );
	#if defined( USE_LIGHT_PROBES )
		irradiance += getLightProbeIrradiance( lightProbe, geometryNormal );
	#endif
	#if ( NUM_HEMI_LIGHTS > 0 )
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_HEMI_LIGHTS; i ++ ) {
			irradiance += getHemisphereLightIrradiance( hemisphereLights[ i ], geometryNormal );
		}
		#pragma unroll_loop_end
	#endif
	#ifdef USE_LIGHT_PROBES_GRID
		vec3 probeWorldPos = ( ( vec4( geometryPosition, 1.0 ) - viewMatrix[ 3 ] ) * viewMatrix ).xyz;
		vec3 probeWorldNormal = transformNormalByInverseViewMatrix( geometryNormal, viewMatrix );
		irradiance += getLightProbeGridIrradiance( probeWorldPos, probeWorldNormal );
	#endif
#endif
#if defined( RE_IndirectSpecular )
	vec3 radiance = vec3( 0.0 );
	vec3 clearcoatRadiance = vec3( 0.0 );
#endif`,OH=`#if defined( RE_IndirectDiffuse )
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		vec3 lightMapIrradiance = lightMapTexel.rgb * lightMapIntensity;
		irradiance += lightMapIrradiance;
	#endif
	#if defined( USE_ENVMAP ) && defined( ENVMAP_TYPE_CUBE_UV )
		#if defined( STANDARD ) || defined( LAMBERT ) || defined( PHONG )
			iblIrradiance += getIBLIrradiance( geometryNormal );
		#endif
	#endif
#endif
#if defined( USE_ENVMAP ) && defined( RE_IndirectSpecular )
	#ifdef USE_ANISOTROPY
		radiance += getIBLAnisotropyRadiance( geometryViewDir, geometryNormal, material.roughness, material.anisotropyB, material.anisotropy );
	#else
		radiance += getIBLRadiance( geometryViewDir, geometryNormal, material.roughness );
	#endif
	#ifdef USE_CLEARCOAT
		clearcoatRadiance += getIBLRadiance( geometryViewDir, geometryClearcoatNormal, material.clearcoatRoughness );
	#endif
#endif`,kH=`#if defined( RE_IndirectDiffuse )
	#if defined( LAMBERT ) || defined( PHONG )
		irradiance += iblIrradiance;
	#endif
	RE_IndirectDiffuse( irradiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif
#if defined( RE_IndirectSpecular )
	RE_IndirectSpecular( radiance, iblIrradiance, clearcoatRadiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif`,MH=`#ifdef USE_LIGHT_PROBES_GRID
uniform highp sampler3D probesSH;
uniform vec3 probesMin;
uniform vec3 probesMax;
uniform vec3 probesResolution;
vec3 getLightProbeGridIrradiance( vec3 worldPos, vec3 worldNormal ) {
	vec3 res = probesResolution;
	vec3 gridRange = probesMax - probesMin;
	vec3 resMinusOne = res - 1.0;
	vec3 probeSpacing = gridRange / resMinusOne;
	vec3 samplePos = worldPos + worldNormal * probeSpacing * 0.5;
	vec3 uvw = clamp( ( samplePos - probesMin ) / gridRange, 0.0, 1.0 );
	uvw = uvw * resMinusOne / res + 0.5 / res;
	float nz          = res.z;
	float paddedSlices = nz + 2.0;
	float atlasDepth  = 7.0 * paddedSlices;
	float uvZBase     = uvw.z * nz + 1.0;
	vec4 s0 = texture( probesSH, vec3( uvw.xy, ( uvZBase                       ) / atlasDepth ) );
	vec4 s1 = texture( probesSH, vec3( uvw.xy, ( uvZBase +       paddedSlices   ) / atlasDepth ) );
	vec4 s2 = texture( probesSH, vec3( uvw.xy, ( uvZBase + 2.0 * paddedSlices   ) / atlasDepth ) );
	vec4 s3 = texture( probesSH, vec3( uvw.xy, ( uvZBase + 3.0 * paddedSlices   ) / atlasDepth ) );
	vec4 s4 = texture( probesSH, vec3( uvw.xy, ( uvZBase + 4.0 * paddedSlices   ) / atlasDepth ) );
	vec4 s5 = texture( probesSH, vec3( uvw.xy, ( uvZBase + 5.0 * paddedSlices   ) / atlasDepth ) );
	vec4 s6 = texture( probesSH, vec3( uvw.xy, ( uvZBase + 6.0 * paddedSlices   ) / atlasDepth ) );
	vec3 c0 = s0.xyz;
	vec3 c1 = vec3( s0.w, s1.xy );
	vec3 c2 = vec3( s1.zw, s2.x );
	vec3 c3 = s2.yzw;
	vec3 c4 = s3.xyz;
	vec3 c5 = vec3( s3.w, s4.xy );
	vec3 c6 = vec3( s4.zw, s5.x );
	vec3 c7 = s5.yzw;
	vec3 c8 = s6.xyz;
	float x = worldNormal.x, y = worldNormal.y, z = worldNormal.z;
	vec3 result = c0 * 0.886227;
	result += c1 * 2.0 * 0.511664 * y;
	result += c2 * 2.0 * 0.511664 * z;
	result += c3 * 2.0 * 0.511664 * x;
	result += c4 * 2.0 * 0.429043 * x * y;
	result += c5 * 2.0 * 0.429043 * y * z;
	result += c6 * ( 0.743125 * z * z - 0.247708 );
	result += c7 * 2.0 * 0.429043 * x * z;
	result += c8 * 0.429043 * ( x * x - y * y );
	return max( result, vec3( 0.0 ) );
}
#endif`,LH=`#if defined( USE_LOGARITHMIC_DEPTH_BUFFER )
	gl_FragDepth = vIsPerspective == 0.0 ? gl_FragCoord.z : log2( vFragDepth ) * logDepthBufFC * 0.5;
#endif`,VH=`#if defined( USE_LOGARITHMIC_DEPTH_BUFFER )
	uniform float logDepthBufFC;
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,BH=`#ifdef USE_LOGARITHMIC_DEPTH_BUFFER
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,zH=`#ifdef USE_LOGARITHMIC_DEPTH_BUFFER
	vFragDepth = 1.0 + gl_Position.w;
	vIsPerspective = float( isPerspectiveMatrix( projectionMatrix ) );
#endif`,IH=`#ifdef USE_MAP
	vec4 sampledDiffuseColor = texture2D( map, vMapUv );
	#ifdef DECODE_VIDEO_TEXTURE
		sampledDiffuseColor = sRGBTransferEOTF( sampledDiffuseColor );
	#endif
	diffuseColor *= sampledDiffuseColor;
#endif`,AH=`#ifdef USE_MAP
	uniform sampler2D map;
#endif`,wH=`#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
	#if defined( USE_POINTS_UV )
		vec2 uv = vUv;
	#else
		vec2 uv = ( uvTransform * vec3( gl_PointCoord.x, 1.0 - gl_PointCoord.y, 1 ) ).xy;
	#endif
#endif
#ifdef USE_MAP
	diffuseColor *= texture2D( map, uv );
#endif
#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, uv ).g;
#endif`,CH=`#if defined( USE_POINTS_UV )
	varying vec2 vUv;
#else
	#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
		uniform mat3 uvTransform;
	#endif
#endif
#ifdef USE_MAP
	uniform sampler2D map;
#endif
#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,_H=`float metalnessFactor = metalness;
#ifdef USE_METALNESSMAP
	vec4 texelMetalness = texture2D( metalnessMap, vMetalnessMapUv );
	metalnessFactor *= texelMetalness.b;
#endif`,PH=`#ifdef USE_METALNESSMAP
	uniform sampler2D metalnessMap;
#endif`,TH=`#ifdef USE_INSTANCING_MORPH
	float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	float morphTargetBaseInfluence = texelFetch( morphTexture, ivec2( 0, gl_InstanceID ), 0 ).r;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		morphTargetInfluences[i] =  texelFetch( morphTexture, ivec2( i + 1, gl_InstanceID ), 0 ).r;
	}
#endif`,SH=`#if defined( USE_MORPHCOLORS )
	vColor *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		#if defined( USE_COLOR_ALPHA )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ) * morphTargetInfluences[ i ];
		#elif defined( USE_COLOR )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ).rgb * morphTargetInfluences[ i ];
		#endif
	}
#endif`,jH=`#ifdef USE_MORPHNORMALS
	objectNormal *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) objectNormal += getMorph( gl_VertexID, i, 1 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,yH=`#ifdef USE_MORPHTARGETS
	#ifndef USE_INSTANCING_MORPH
		uniform float morphTargetBaseInfluence;
		uniform float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	#endif
	uniform sampler2DArray morphTargetsTexture;
	uniform ivec2 morphTargetsTextureSize;
	vec4 getMorph( const in int vertexIndex, const in int morphTargetIndex, const in int offset ) {
		int texelIndex = vertexIndex * MORPHTARGETS_TEXTURE_STRIDE + offset;
		int y = texelIndex / morphTargetsTextureSize.x;
		int x = texelIndex - y * morphTargetsTextureSize.x;
		ivec3 morphUV = ivec3( x, y, morphTargetIndex );
		return texelFetch( morphTargetsTexture, morphUV, 0 );
	}
#endif`,fH=`#ifdef USE_MORPHTARGETS
	transformed *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) transformed += getMorph( gl_VertexID, i, 0 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,vH=`float faceDirection = gl_FrontFacing ? 1.0 : - 1.0;
#ifdef FLAT_SHADED
	vec3 fdx = dFdx( vViewPosition );
	vec3 fdy = dFdy( vViewPosition );
	vec3 normal = normalize( cross( fdx, fdy ) );
#else
	vec3 normal = normalize( vNormal );
	#ifdef DOUBLE_SIDED
		normal *= faceDirection;
	#endif
#endif
#if defined( USE_NORMALMAP_TANGENTSPACE ) || defined( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY )
	#ifdef USE_TANGENT
		mat3 tbn = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn = getTangentFrame( - vViewPosition, normal,
		#if defined( USE_NORMALMAP )
			vNormalMapUv
		#elif defined( USE_CLEARCOAT_NORMALMAP )
			vClearcoatNormalMapUv
		#else
			vUv
		#endif
		);
	#endif
	#ifdef DOUBLE_SIDED
		tbn[0] *= faceDirection;
		tbn[1] *= faceDirection;
	#endif
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	#ifdef USE_TANGENT
		mat3 tbn2 = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn2 = getTangentFrame( - vViewPosition, normal, vClearcoatNormalMapUv );
	#endif
	#ifdef DOUBLE_SIDED
		tbn2[0] *= faceDirection;
		tbn2[1] *= faceDirection;
	#endif
#endif
vec3 nonPerturbedNormal = normal;`,bH=`#ifdef USE_NORMALMAP_OBJECTSPACE
	normal = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	#ifdef FLIP_SIDED
		normal = - normal;
	#endif
	#ifdef DOUBLE_SIDED
		normal = normal * faceDirection;
	#endif
	normal = normalize( normalMatrix * normal );
#elif defined( USE_NORMALMAP_TANGENTSPACE )
	vec3 mapN = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	#if defined( USE_PACKED_NORMALMAP )
		mapN = vec3( mapN.xy, sqrt( saturate( 1.0 - dot( mapN.xy, mapN.xy ) ) ) );
	#endif
	mapN.xy *= normalScale;
	normal = normalize( tbn * mapN );
#elif defined( USE_BUMPMAP )
	normal = perturbNormalArb( - vViewPosition, normal, dHdxy_fwd(), faceDirection );
#endif`,hH=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,xH=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,gH=`#ifndef FLAT_SHADED
	vNormal = normalize( transformedNormal );
	#ifdef USE_TANGENT
		vTangent = normalize( transformedTangent );
		vBitangent = normalize( cross( vNormal, vTangent ) * tangent.w );
		#ifdef FLIP_SIDED
			vBitangent = - vBitangent;
		#endif
	#endif
#endif`,pH=`#ifdef USE_NORMALMAP
	uniform sampler2D normalMap;
	uniform vec2 normalScale;
#endif
#ifdef USE_NORMALMAP_OBJECTSPACE
	uniform mat3 normalMatrix;
#endif
#if ! defined ( USE_TANGENT ) && ( defined ( USE_NORMALMAP_TANGENTSPACE ) || defined ( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY ) )
	mat3 getTangentFrame( vec3 eye_pos, vec3 surf_norm, vec2 uv ) {
		vec3 q0 = dFdx( eye_pos.xyz );
		vec3 q1 = dFdy( eye_pos.xyz );
		vec2 st0 = dFdx( uv.st );
		vec2 st1 = dFdy( uv.st );
		vec3 N = surf_norm;
		vec3 q1perp = cross( q1, N );
		vec3 q0perp = cross( N, q0 );
		vec3 T = q1perp * st0.x + q0perp * st1.x;
		vec3 B = q1perp * st0.y + q0perp * st1.y;
		float det = max( dot( T, T ), dot( B, B ) );
		float scale = ( det == 0.0 ) ? 0.0 : inversesqrt( det );
		return mat3( T * scale, B * scale, N );
	}
#endif`,mH=`#ifdef USE_CLEARCOAT
	vec3 clearcoatNormal = nonPerturbedNormal;
#endif`,dH=`#ifdef USE_CLEARCOAT_NORMALMAP
	vec3 clearcoatMapN = texture2D( clearcoatNormalMap, vClearcoatNormalMapUv ).xyz * 2.0 - 1.0;
	clearcoatMapN.xy *= clearcoatNormalScale;
	clearcoatNormal = normalize( tbn2 * clearcoatMapN );
#endif`,lH=`#ifdef USE_CLEARCOATMAP
	uniform sampler2D clearcoatMap;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform sampler2D clearcoatNormalMap;
	uniform vec2 clearcoatNormalScale;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform sampler2D clearcoatRoughnessMap;
#endif`,uH=`#ifdef USE_IRIDESCENCEMAP
	uniform sampler2D iridescenceMap;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform sampler2D iridescenceThicknessMap;
#endif`,cH=`#ifdef OPAQUE
diffuseColor.a = 1.0;
#endif
#ifdef USE_TRANSMISSION
diffuseColor.a *= material.transmissionAlpha;
#endif
gl_FragColor = vec4( outgoingLight, diffuseColor.a );`,nH=`vec3 packNormalToRGB( const in vec3 normal ) {
	return normalize( normal ) * 0.5 + 0.5;
}
vec3 unpackRGBToNormal( const in vec3 rgb ) {
	return 2.0 * rgb.xyz - 1.0;
}
const float PackUpscale = 256. / 255.;const float UnpackDownscale = 255. / 256.;const float ShiftRight8 = 1. / 256.;
const float Inv255 = 1. / 255.;
const vec4 PackFactors = vec4( 1.0, 256.0, 256.0 * 256.0, 256.0 * 256.0 * 256.0 );
const vec2 UnpackFactors2 = vec2( UnpackDownscale, 1.0 / PackFactors.g );
const vec3 UnpackFactors3 = vec3( UnpackDownscale / PackFactors.rg, 1.0 / PackFactors.b );
const vec4 UnpackFactors4 = vec4( UnpackDownscale / PackFactors.rgb, 1.0 / PackFactors.a );
vec4 packDepthToRGBA( const in float v ) {
	if( v <= 0.0 )
		return vec4( 0., 0., 0., 0. );
	if( v >= 1.0 )
		return vec4( 1., 1., 1., 1. );
	float vuf;
	float af = modf( v * PackFactors.a, vuf );
	float bf = modf( vuf * ShiftRight8, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec4( vuf * Inv255, gf * PackUpscale, bf * PackUpscale, af );
}
vec3 packDepthToRGB( const in float v ) {
	if( v <= 0.0 )
		return vec3( 0., 0., 0. );
	if( v >= 1.0 )
		return vec3( 1., 1., 1. );
	float vuf;
	float bf = modf( v * PackFactors.b, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec3( vuf * Inv255, gf * PackUpscale, bf );
}
vec2 packDepthToRG( const in float v ) {
	if( v <= 0.0 )
		return vec2( 0., 0. );
	if( v >= 1.0 )
		return vec2( 1., 1. );
	float vuf;
	float gf = modf( v * 256., vuf );
	return vec2( vuf * Inv255, gf );
}
float unpackRGBAToDepth( const in vec4 v ) {
	return dot( v, UnpackFactors4 );
}
float unpackRGBToDepth( const in vec3 v ) {
	return dot( v, UnpackFactors3 );
}
float unpackRGToDepth( const in vec2 v ) {
	return v.r * UnpackFactors2.r + v.g * UnpackFactors2.g;
}
vec4 pack2HalfToRGBA( const in vec2 v ) {
	vec4 r = vec4( v.x, fract( v.x * 255.0 ), v.y, fract( v.y * 255.0 ) );
	return vec4( r.x - r.y / 255.0, r.y, r.z - r.w / 255.0, r.w );
}
vec2 unpackRGBATo2Half( const in vec4 v ) {
	return vec2( v.x + ( v.y / 255.0 ), v.z + ( v.w / 255.0 ) );
}
float viewZToOrthographicDepth( const in float viewZ, const in float near, const in float far ) {
	return ( viewZ + near ) / ( near - far );
}
float orthographicDepthToViewZ( const in float depth, const in float near, const in float far ) {
	#ifdef USE_REVERSED_DEPTH_BUFFER
	
		return depth * ( far - near ) - far;
	#else
		return depth * ( near - far ) - near;
	#endif
}
float viewZToPerspectiveDepth( const in float viewZ, const in float near, const in float far ) {
	return ( ( near + viewZ ) * far ) / ( ( far - near ) * viewZ );
}
float perspectiveDepthToViewZ( const in float depth, const in float near, const in float far ) {
	
	#ifdef USE_REVERSED_DEPTH_BUFFER
		return ( near * far ) / ( ( near - far ) * depth - near );
	#else
		return ( near * far ) / ( ( far - near ) * depth - far );
	#endif
}`,sH=`#ifdef PREMULTIPLIED_ALPHA
	gl_FragColor.rgb *= gl_FragColor.a;
#endif`,iH=`vec4 mvPosition = vec4( transformed, 1.0 );
#ifdef USE_BATCHING
	mvPosition = batchingMatrix * mvPosition;
#endif
#ifdef USE_INSTANCING
	mvPosition = instanceMatrix * mvPosition;
#endif
mvPosition = modelViewMatrix * mvPosition;
gl_Position = projectionMatrix * mvPosition;`,oH=`#ifdef DITHERING
	gl_FragColor.rgb = dithering( gl_FragColor.rgb );
#endif`,aH=`#ifdef DITHERING
	vec3 dithering( vec3 color ) {
		float grid_position = rand( gl_FragCoord.xy );
		vec3 dither_shift_RGB = vec3( 0.25 / 255.0, -0.25 / 255.0, 0.25 / 255.0 );
		dither_shift_RGB = mix( 2.0 * dither_shift_RGB, -2.0 * dither_shift_RGB, grid_position );
		return color + dither_shift_RGB;
	}
#endif`,rH=`float roughnessFactor = roughness;
#ifdef USE_ROUGHNESSMAP
	vec4 texelRoughness = texture2D( roughnessMap, vRoughnessMapUv );
	roughnessFactor *= texelRoughness.g;
#endif`,tH=`#ifdef USE_ROUGHNESSMAP
	uniform sampler2D roughnessMap;
#endif`,eH=`#if NUM_SPOT_LIGHT_COORDS > 0
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#if NUM_SPOT_LIGHT_MAPS > 0
	uniform sampler2D spotLightMap[ NUM_SPOT_LIGHT_MAPS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		#if defined( SHADOWMAP_TYPE_PCF )
			uniform sampler2DShadow directionalShadowMap[ NUM_DIR_LIGHT_SHADOWS ];
		#else
			uniform sampler2D directionalShadowMap[ NUM_DIR_LIGHT_SHADOWS ];
		#endif
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		#if defined( SHADOWMAP_TYPE_PCF )
			uniform sampler2DShadow spotShadowMap[ NUM_SPOT_LIGHT_SHADOWS ];
		#else
			uniform sampler2D spotShadowMap[ NUM_SPOT_LIGHT_SHADOWS ];
		#endif
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		#if defined( SHADOWMAP_TYPE_PCF )
			uniform samplerCubeShadow pointShadowMap[ NUM_POINT_LIGHT_SHADOWS ];
		#elif defined( SHADOWMAP_TYPE_BASIC )
			uniform samplerCube pointShadowMap[ NUM_POINT_LIGHT_SHADOWS ];
		#endif
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
	#if defined( SHADOWMAP_TYPE_PCF )
		float interleavedGradientNoise( vec2 position ) {
			return fract( 52.9829189 * fract( dot( position, vec2( 0.06711056, 0.00583715 ) ) ) );
		}
		vec2 vogelDiskSample( int sampleIndex, int samplesCount, float phi ) {
			const float goldenAngle = 2.399963229728653;
			float r = sqrt( ( float( sampleIndex ) + 0.5 ) / float( samplesCount ) );
			float theta = float( sampleIndex ) * goldenAngle + phi;
			return vec2( cos( theta ), sin( theta ) ) * r;
		}
	#endif
	#if defined( SHADOWMAP_TYPE_PCF )
		float getShadow( sampler2DShadow shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord ) {
			float shadow = 1.0;
			shadowCoord.xyz /= shadowCoord.w;
			shadowCoord.z += shadowBias;
			bool inFrustum = shadowCoord.x >= 0.0 && shadowCoord.x <= 1.0 && shadowCoord.y >= 0.0 && shadowCoord.y <= 1.0;
			bool frustumTest = inFrustum && shadowCoord.z <= 1.0;
			if ( frustumTest ) {
				vec2 texelSize = vec2( 1.0 ) / shadowMapSize;
				float radius = shadowRadius * texelSize.x;
				float phi = interleavedGradientNoise( gl_FragCoord.xy ) * PI2;
				shadow = (
					texture( shadowMap, vec3( shadowCoord.xy + vogelDiskSample( 0, 5, phi ) * radius, shadowCoord.z ) ) +
					texture( shadowMap, vec3( shadowCoord.xy + vogelDiskSample( 1, 5, phi ) * radius, shadowCoord.z ) ) +
					texture( shadowMap, vec3( shadowCoord.xy + vogelDiskSample( 2, 5, phi ) * radius, shadowCoord.z ) ) +
					texture( shadowMap, vec3( shadowCoord.xy + vogelDiskSample( 3, 5, phi ) * radius, shadowCoord.z ) ) +
					texture( shadowMap, vec3( shadowCoord.xy + vogelDiskSample( 4, 5, phi ) * radius, shadowCoord.z ) )
				) * 0.2;
			}
			return mix( 1.0, shadow, shadowIntensity );
		}
	#elif defined( SHADOWMAP_TYPE_VSM )
		float getShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord ) {
			float shadow = 1.0;
			shadowCoord.xyz /= shadowCoord.w;
			#ifdef USE_REVERSED_DEPTH_BUFFER
				shadowCoord.z -= shadowBias;
			#else
				shadowCoord.z += shadowBias;
			#endif
			bool inFrustum = shadowCoord.x >= 0.0 && shadowCoord.x <= 1.0 && shadowCoord.y >= 0.0 && shadowCoord.y <= 1.0;
			bool frustumTest = inFrustum && shadowCoord.z <= 1.0;
			if ( frustumTest ) {
				vec2 distribution = texture2D( shadowMap, shadowCoord.xy ).rg;
				float mean = distribution.x;
				float variance = distribution.y * distribution.y;
				#ifdef USE_REVERSED_DEPTH_BUFFER
					float hard_shadow = step( mean, shadowCoord.z );
				#else
					float hard_shadow = step( shadowCoord.z, mean );
				#endif
				
				if ( hard_shadow == 1.0 ) {
					shadow = 1.0;
				} else {
					variance = max( variance, 0.0000001 );
					float d = shadowCoord.z - mean;
					float p_max = variance / ( variance + d * d );
					p_max = clamp( ( p_max - 0.3 ) / 0.65, 0.0, 1.0 );
					shadow = max( hard_shadow, p_max );
				}
			}
			return mix( 1.0, shadow, shadowIntensity );
		}
	#else
		float getShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord ) {
			float shadow = 1.0;
			shadowCoord.xyz /= shadowCoord.w;
			#ifdef USE_REVERSED_DEPTH_BUFFER
				shadowCoord.z -= shadowBias;
			#else
				shadowCoord.z += shadowBias;
			#endif
			bool inFrustum = shadowCoord.x >= 0.0 && shadowCoord.x <= 1.0 && shadowCoord.y >= 0.0 && shadowCoord.y <= 1.0;
			bool frustumTest = inFrustum && shadowCoord.z <= 1.0;
			if ( frustumTest ) {
				float depth = texture2D( shadowMap, shadowCoord.xy ).r;
				#ifdef USE_REVERSED_DEPTH_BUFFER
					shadow = step( depth, shadowCoord.z );
				#else
					shadow = step( shadowCoord.z, depth );
				#endif
			}
			return mix( 1.0, shadow, shadowIntensity );
		}
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
	#if defined( SHADOWMAP_TYPE_PCF )
	float getPointShadow( samplerCubeShadow shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord, float shadowCameraNear, float shadowCameraFar ) {
		float shadow = 1.0;
		vec3 lightToPosition = shadowCoord.xyz;
		vec3 bd3D = normalize( lightToPosition );
		vec3 absVec = abs( lightToPosition );
		float viewSpaceZ = max( max( absVec.x, absVec.y ), absVec.z );
		if ( viewSpaceZ - shadowCameraFar <= 0.0 && viewSpaceZ - shadowCameraNear >= 0.0 ) {
			#ifdef USE_REVERSED_DEPTH_BUFFER
				float dp = ( shadowCameraNear * ( shadowCameraFar - viewSpaceZ ) ) / ( viewSpaceZ * ( shadowCameraFar - shadowCameraNear ) );
				dp -= shadowBias;
			#else
				float dp = ( shadowCameraFar * ( viewSpaceZ - shadowCameraNear ) ) / ( viewSpaceZ * ( shadowCameraFar - shadowCameraNear ) );
				dp += shadowBias;
			#endif
			float texelSize = shadowRadius / shadowMapSize.x;
			vec3 absDir = abs( bd3D );
			vec3 tangent = absDir.x > absDir.z ? vec3( 0.0, 1.0, 0.0 ) : vec3( 1.0, 0.0, 0.0 );
			tangent = normalize( cross( bd3D, tangent ) );
			vec3 bitangent = cross( bd3D, tangent );
			float phi = interleavedGradientNoise( gl_FragCoord.xy ) * PI2;
			vec2 sample0 = vogelDiskSample( 0, 5, phi );
			vec2 sample1 = vogelDiskSample( 1, 5, phi );
			vec2 sample2 = vogelDiskSample( 2, 5, phi );
			vec2 sample3 = vogelDiskSample( 3, 5, phi );
			vec2 sample4 = vogelDiskSample( 4, 5, phi );
			shadow = (
				texture( shadowMap, vec4( bd3D + ( tangent * sample0.x + bitangent * sample0.y ) * texelSize, dp ) ) +
				texture( shadowMap, vec4( bd3D + ( tangent * sample1.x + bitangent * sample1.y ) * texelSize, dp ) ) +
				texture( shadowMap, vec4( bd3D + ( tangent * sample2.x + bitangent * sample2.y ) * texelSize, dp ) ) +
				texture( shadowMap, vec4( bd3D + ( tangent * sample3.x + bitangent * sample3.y ) * texelSize, dp ) ) +
				texture( shadowMap, vec4( bd3D + ( tangent * sample4.x + bitangent * sample4.y ) * texelSize, dp ) )
			) * 0.2;
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
	#elif defined( SHADOWMAP_TYPE_BASIC )
	float getPointShadow( samplerCube shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord, float shadowCameraNear, float shadowCameraFar ) {
		float shadow = 1.0;
		vec3 lightToPosition = shadowCoord.xyz;
		vec3 absVec = abs( lightToPosition );
		float viewSpaceZ = max( max( absVec.x, absVec.y ), absVec.z );
		if ( viewSpaceZ - shadowCameraFar <= 0.0 && viewSpaceZ - shadowCameraNear >= 0.0 ) {
			float dp = ( shadowCameraFar * ( viewSpaceZ - shadowCameraNear ) ) / ( viewSpaceZ * ( shadowCameraFar - shadowCameraNear ) );
			dp += shadowBias;
			vec3 bd3D = normalize( lightToPosition );
			float depth = textureCube( shadowMap, bd3D ).r;
			#ifdef USE_REVERSED_DEPTH_BUFFER
				depth = 1.0 - depth;
			#endif
			shadow = step( dp, depth );
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
	#endif
	#endif
#endif`,JY=`#if NUM_SPOT_LIGHT_COORDS > 0
	uniform mat4 spotLightMatrix[ NUM_SPOT_LIGHT_COORDS ];
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform mat4 directionalShadowMatrix[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		uniform mat4 pointShadowMatrix[ NUM_POINT_LIGHT_SHADOWS ];
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
#endif`,QY=`#if ( defined( USE_SHADOWMAP ) && ( NUM_DIR_LIGHT_SHADOWS > 0 || NUM_POINT_LIGHT_SHADOWS > 0 ) ) || ( NUM_SPOT_LIGHT_COORDS > 0 )
	#ifdef HAS_NORMAL
		vec3 shadowWorldNormal = transformNormalByInverseViewMatrix( transformedNormal, viewMatrix );
	#else
		vec3 shadowWorldNormal = vec3( 0.0 );
	#endif
	vec4 shadowWorldPosition;
#endif
#if defined( USE_SHADOWMAP )
	#if NUM_DIR_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * directionalLightShadows[ i ].shadowNormalBias, 0 );
			vDirectionalShadowCoord[ i ] = directionalShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * pointLightShadows[ i ].shadowNormalBias, 0 );
			vPointShadowCoord[ i ] = pointShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
#endif
#if NUM_SPOT_LIGHT_COORDS > 0
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_COORDS; i ++ ) {
		shadowWorldPosition = worldPosition;
		#if ( defined( USE_SHADOWMAP ) && UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
			shadowWorldPosition.xyz += shadowWorldNormal * spotLightShadows[ i ].shadowNormalBias;
		#endif
		vSpotLightCoord[ i ] = spotLightMatrix[ i ] * shadowWorldPosition;
	}
	#pragma unroll_loop_end
#endif`,$Y=`float getShadowMask() {
	float shadow = 1.0;
	#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
		directionalLight = directionalLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( directionalShadowMap[ i ], directionalLight.shadowMapSize, directionalLight.shadowIntensity, directionalLight.shadowBias, directionalLight.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_SHADOWS; i ++ ) {
		spotLight = spotLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( spotShadowMap[ i ], spotLight.shadowMapSize, spotLight.shadowIntensity, spotLight.shadowBias, spotLight.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0 && ( defined( SHADOWMAP_TYPE_PCF ) || defined( SHADOWMAP_TYPE_BASIC ) )
	PointLightShadow pointLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
		pointLight = pointLightShadows[ i ];
		shadow *= receiveShadow ? getPointShadow( pointShadowMap[ i ], pointLight.shadowMapSize, pointLight.shadowIntensity, pointLight.shadowBias, pointLight.shadowRadius, vPointShadowCoord[ i ], pointLight.shadowCameraNear, pointLight.shadowCameraFar ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#endif
	return shadow;
}`,ZY=`#ifdef USE_SKINNING
	mat4 boneMatX = getBoneMatrix( skinIndex.x );
	mat4 boneMatY = getBoneMatrix( skinIndex.y );
	mat4 boneMatZ = getBoneMatrix( skinIndex.z );
	mat4 boneMatW = getBoneMatrix( skinIndex.w );
#endif`,WY=`#ifdef USE_SKINNING
	uniform mat4 bindMatrix;
	uniform mat4 bindMatrixInverse;
	uniform highp sampler2D boneTexture;
	mat4 getBoneMatrix( const in float i ) {
		int size = textureSize( boneTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( boneTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( boneTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( boneTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( boneTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
#endif`,KY=`#ifdef USE_SKINNING
	vec4 skinVertex = bindMatrix * vec4( transformed, 1.0 );
	vec4 skinned = vec4( 0.0 );
	skinned += boneMatX * skinVertex * skinWeight.x;
	skinned += boneMatY * skinVertex * skinWeight.y;
	skinned += boneMatZ * skinVertex * skinWeight.z;
	skinned += boneMatW * skinVertex * skinWeight.w;
	transformed = ( bindMatrixInverse * skinned ).xyz;
#endif`,HY=`#ifdef USE_SKINNING
	mat4 skinMatrix = mat4( 0.0 );
	skinMatrix += skinWeight.x * boneMatX;
	skinMatrix += skinWeight.y * boneMatY;
	skinMatrix += skinWeight.z * boneMatZ;
	skinMatrix += skinWeight.w * boneMatW;
	skinMatrix = bindMatrixInverse * skinMatrix * bindMatrix;
	objectNormal = vec4( skinMatrix * vec4( objectNormal, 0.0 ) ).xyz;
	#ifdef USE_TANGENT
		objectTangent = vec4( skinMatrix * vec4( objectTangent, 0.0 ) ).xyz;
	#endif
#endif`,YY=`float specularStrength;
#ifdef USE_SPECULARMAP
	vec4 texelSpecular = texture2D( specularMap, vSpecularMapUv );
	specularStrength = texelSpecular.r;
#else
	specularStrength = 1.0;
#endif`,XY=`#ifdef USE_SPECULARMAP
	uniform sampler2D specularMap;
#endif`,UY=`#if defined( TONE_MAPPING )
	gl_FragColor.rgb = toneMapping( gl_FragColor.rgb );
#endif`,GY=`#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
uniform float toneMappingExposure;
vec3 LinearToneMapping( vec3 color ) {
	return saturate( toneMappingExposure * color );
}
vec3 ReinhardToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	return saturate( color / ( vec3( 1.0 ) + color ) );
}
vec3 CineonToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	color = max( vec3( 0.0 ), color - 0.004 );
	return pow( ( color * ( 6.2 * color + 0.5 ) ) / ( color * ( 6.2 * color + 1.7 ) + 0.06 ), vec3( 2.2 ) );
}
vec3 RRTAndODTFit( vec3 v ) {
	vec3 a = v * ( v + 0.0245786 ) - 0.000090537;
	vec3 b = v * ( 0.983729 * v + 0.4329510 ) + 0.238081;
	return a / b;
}
vec3 ACESFilmicToneMapping( vec3 color ) {
	const mat3 ACESInputMat = mat3(
		vec3( 0.59719, 0.07600, 0.02840 ),		vec3( 0.35458, 0.90834, 0.13383 ),
		vec3( 0.04823, 0.01566, 0.83777 )
	);
	const mat3 ACESOutputMat = mat3(
		vec3(  1.60475, -0.10208, -0.00327 ),		vec3( -0.53108,  1.10813, -0.07276 ),
		vec3( -0.07367, -0.00605,  1.07602 )
	);
	color *= toneMappingExposure / 0.6;
	color = ACESInputMat * color;
	color = RRTAndODTFit( color );
	color = ACESOutputMat * color;
	return saturate( color );
}
const mat3 LINEAR_REC2020_TO_LINEAR_SRGB = mat3(
	vec3( 1.6605, - 0.1246, - 0.0182 ),
	vec3( - 0.5876, 1.1329, - 0.1006 ),
	vec3( - 0.0728, - 0.0083, 1.1187 )
);
const mat3 LINEAR_SRGB_TO_LINEAR_REC2020 = mat3(
	vec3( 0.6274, 0.0691, 0.0164 ),
	vec3( 0.3293, 0.9195, 0.0880 ),
	vec3( 0.0433, 0.0113, 0.8956 )
);
vec3 agxDefaultContrastApprox( vec3 x ) {
	vec3 x2 = x * x;
	vec3 x4 = x2 * x2;
	return + 15.5 * x4 * x2
		- 40.14 * x4 * x
		+ 31.96 * x4
		- 6.868 * x2 * x
		+ 0.4298 * x2
		+ 0.1191 * x
		- 0.00232;
}
vec3 AgXToneMapping( vec3 color ) {
	const mat3 AgXInsetMatrix = mat3(
		vec3( 0.856627153315983, 0.137318972929847, 0.11189821299995 ),
		vec3( 0.0951212405381588, 0.761241990602591, 0.0767994186031903 ),
		vec3( 0.0482516061458583, 0.101439036467562, 0.811302368396859 )
	);
	const mat3 AgXOutsetMatrix = mat3(
		vec3( 1.1271005818144368, - 0.1413297634984383, - 0.14132976349843826 ),
		vec3( - 0.11060664309660323, 1.157823702216272, - 0.11060664309660294 ),
		vec3( - 0.016493938717834573, - 0.016493938717834257, 1.2519364065950405 )
	);
	const float AgxMinEv = - 12.47393;	const float AgxMaxEv = 4.026069;
	color *= toneMappingExposure;
	color = LINEAR_SRGB_TO_LINEAR_REC2020 * color;
	color = AgXInsetMatrix * color;
	color = max( color, 1e-10 );	color = log2( color );
	color = ( color - AgxMinEv ) / ( AgxMaxEv - AgxMinEv );
	color = clamp( color, 0.0, 1.0 );
	color = agxDefaultContrastApprox( color );
	color = AgXOutsetMatrix * color;
	color = pow( max( vec3( 0.0 ), color ), vec3( 2.2 ) );
	color = LINEAR_REC2020_TO_LINEAR_SRGB * color;
	color = clamp( color, 0.0, 1.0 );
	return color;
}
vec3 NeutralToneMapping( vec3 color ) {
	const float StartCompression = 0.8 - 0.04;
	const float Desaturation = 0.15;
	color *= toneMappingExposure;
	float x = min( color.r, min( color.g, color.b ) );
	float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
	color -= offset;
	float peak = max( color.r, max( color.g, color.b ) );
	if ( peak < StartCompression ) return color;
	float d = 1. - StartCompression;
	float newPeak = 1. - d * d / ( peak + d - StartCompression );
	color *= newPeak / peak;
	float g = 1. - 1. / ( Desaturation * ( peak - newPeak ) + 1. );
	return mix( color, vec3( newPeak ), g );
}
vec3 CustomToneMapping( vec3 color ) { return color; }`,EY=`#ifdef USE_TRANSMISSION
	material.transmission = transmission;
	material.transmissionAlpha = 1.0;
	material.thickness = thickness;
	material.attenuationDistance = attenuationDistance;
	material.attenuationColor = attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		material.transmission *= texture2D( transmissionMap, vTransmissionMapUv ).r;
	#endif
	#ifdef USE_THICKNESSMAP
		material.thickness *= texture2D( thicknessMap, vThicknessMapUv ).g;
	#endif
	vec3 pos = vWorldPosition;
	vec3 v = normalize( cameraPosition - pos );
	vec3 n = transformNormalByInverseViewMatrix( normal, viewMatrix );
	vec4 transmitted = getIBLVolumeRefraction(
		n, v, material.roughness, material.diffuseContribution, material.specularColorBlended, material.specularF90,
		pos, modelMatrix, viewMatrix, projectionMatrix, material.dispersion, material.ior, material.thickness,
		material.attenuationColor, material.attenuationDistance );
	material.transmissionAlpha = mix( material.transmissionAlpha, transmitted.a, material.transmission );
	totalDiffuse = mix( totalDiffuse, transmitted.rgb, material.transmission );
#endif`,NY=`#ifdef USE_TRANSMISSION
	uniform float transmission;
	uniform float thickness;
	uniform float attenuationDistance;
	uniform vec3 attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		uniform sampler2D transmissionMap;
	#endif
	#ifdef USE_THICKNESSMAP
		uniform sampler2D thicknessMap;
	#endif
	uniform vec2 transmissionSamplerSize;
	uniform sampler2D transmissionSamplerMap;
	uniform mat4 modelMatrix;
	uniform mat4 projectionMatrix;
	varying vec3 vWorldPosition;
	float w0( float a ) {
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - a + 3.0 ) - 3.0 ) + 1.0 );
	}
	float w1( float a ) {
		return ( 1.0 / 6.0 ) * ( a *  a * ( 3.0 * a - 6.0 ) + 4.0 );
	}
	float w2( float a ){
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - 3.0 * a + 3.0 ) + 3.0 ) + 1.0 );
	}
	float w3( float a ) {
		return ( 1.0 / 6.0 ) * ( a * a * a );
	}
	float g0( float a ) {
		return w0( a ) + w1( a );
	}
	float g1( float a ) {
		return w2( a ) + w3( a );
	}
	float h0( float a ) {
		return - 1.0 + w1( a ) / ( w0( a ) + w1( a ) );
	}
	float h1( float a ) {
		return 1.0 + w3( a ) / ( w2( a ) + w3( a ) );
	}
	vec4 bicubic( sampler2D tex, vec2 uv, vec4 texelSize, float lod ) {
		uv = uv * texelSize.zw + 0.5;
		vec2 iuv = floor( uv );
		vec2 fuv = fract( uv );
		float g0x = g0( fuv.x );
		float g1x = g1( fuv.x );
		float h0x = h0( fuv.x );
		float h1x = h1( fuv.x );
		float h0y = h0( fuv.y );
		float h1y = h1( fuv.y );
		vec2 p0 = ( vec2( iuv.x + h0x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p1 = ( vec2( iuv.x + h1x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p2 = ( vec2( iuv.x + h0x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		vec2 p3 = ( vec2( iuv.x + h1x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		return g0( fuv.y ) * ( g0x * textureLod( tex, p0, lod ) + g1x * textureLod( tex, p1, lod ) ) +
			g1( fuv.y ) * ( g0x * textureLod( tex, p2, lod ) + g1x * textureLod( tex, p3, lod ) );
	}
	vec4 textureBicubic( sampler2D sampler, vec2 uv, float lod ) {
		vec2 fLodSize = vec2( textureSize( sampler, int( lod ) ) );
		vec2 cLodSize = vec2( textureSize( sampler, int( lod + 1.0 ) ) );
		vec2 fLodSizeInv = 1.0 / fLodSize;
		vec2 cLodSizeInv = 1.0 / cLodSize;
		vec4 fSample = bicubic( sampler, uv, vec4( fLodSizeInv, fLodSize ), floor( lod ) );
		vec4 cSample = bicubic( sampler, uv, vec4( cLodSizeInv, cLodSize ), ceil( lod ) );
		return mix( fSample, cSample, fract( lod ) );
	}
	vec3 getVolumeTransmissionRay( const in vec3 n, const in vec3 v, const in float thickness, const in float ior, const in mat4 modelMatrix ) {
		vec3 refractionVector = refract( - v, normalize( n ), 1.0 / ior );
		vec3 modelScale;
		modelScale.x = length( vec3( modelMatrix[ 0 ].xyz ) );
		modelScale.y = length( vec3( modelMatrix[ 1 ].xyz ) );
		modelScale.z = length( vec3( modelMatrix[ 2 ].xyz ) );
		return normalize( refractionVector ) * thickness * modelScale;
	}
	float applyIorToRoughness( const in float roughness, const in float ior ) {
		return roughness * clamp( ior * 2.0 - 2.0, 0.0, 1.0 );
	}
	vec4 getTransmissionSample( const in vec2 fragCoord, const in float roughness, const in float ior ) {
		float lod = log2( transmissionSamplerSize.x ) * applyIorToRoughness( roughness, ior );
		return textureBicubic( transmissionSamplerMap, fragCoord.xy, lod );
	}
	vec3 volumeAttenuation( const in float transmissionDistance, const in vec3 attenuationColor, const in float attenuationDistance ) {
		if ( isinf( attenuationDistance ) ) {
			return vec3( 1.0 );
		} else {
			vec3 attenuationCoefficient = -log( attenuationColor ) / attenuationDistance;
			vec3 transmittance = exp( - attenuationCoefficient * transmissionDistance );			return transmittance;
		}
	}
	vec4 getIBLVolumeRefraction( const in vec3 n, const in vec3 v, const in float roughness, const in vec3 diffuseColor,
		const in vec3 specularColor, const in float specularF90, const in vec3 position, const in mat4 modelMatrix,
		const in mat4 viewMatrix, const in mat4 projMatrix, const in float dispersion, const in float ior, const in float thickness,
		const in vec3 attenuationColor, const in float attenuationDistance ) {
		vec4 transmittedLight;
		vec3 transmittance;
		#ifdef USE_DISPERSION
			float halfSpread = ( ior - 1.0 ) * 0.025 * dispersion;
			vec3 iors = vec3( ior - halfSpread, ior, ior + halfSpread );
			for ( int i = 0; i < 3; i ++ ) {
				vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, iors[ i ], modelMatrix );
				vec3 refractedRayExit = position + transmissionRay;
				vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
				vec2 refractionCoords = ndcPos.xy / ndcPos.w;
				refractionCoords += 1.0;
				refractionCoords /= 2.0;
				vec4 transmissionSample = getTransmissionSample( refractionCoords, roughness, iors[ i ] );
				transmittedLight[ i ] = transmissionSample[ i ];
				transmittedLight.a += transmissionSample.a;
				transmittance[ i ] = diffuseColor[ i ] * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance )[ i ];
			}
			transmittedLight.a /= 3.0;
		#else
			vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, ior, modelMatrix );
			vec3 refractedRayExit = position + transmissionRay;
			vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
			vec2 refractionCoords = ndcPos.xy / ndcPos.w;
			refractionCoords += 1.0;
			refractionCoords /= 2.0;
			transmittedLight = getTransmissionSample( refractionCoords, roughness, ior );
			transmittance = diffuseColor * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance );
		#endif
		vec3 attenuatedColor = transmittance * transmittedLight.rgb;
		vec3 F = EnvironmentBRDF( n, v, specularColor, specularF90, roughness );
		float transmittanceFactor = ( transmittance.r + transmittance.g + transmittance.b ) / 3.0;
		return vec4( ( 1.0 - F ) * attenuatedColor, 1.0 - ( 1.0 - transmittedLight.a ) * transmittanceFactor );
	}
#endif`,qY=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_SPECULARMAP
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,FY=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	uniform mat3 mapTransform;
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	uniform mat3 alphaMapTransform;
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	uniform mat3 lightMapTransform;
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	uniform mat3 aoMapTransform;
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	uniform mat3 bumpMapTransform;
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	uniform mat3 normalMapTransform;
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_DISPLACEMENTMAP
	uniform mat3 displacementMapTransform;
	varying vec2 vDisplacementMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	uniform mat3 emissiveMapTransform;
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	uniform mat3 metalnessMapTransform;
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	uniform mat3 roughnessMapTransform;
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	uniform mat3 anisotropyMapTransform;
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	uniform mat3 clearcoatMapTransform;
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform mat3 clearcoatNormalMapTransform;
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform mat3 clearcoatRoughnessMapTransform;
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	uniform mat3 sheenColorMapTransform;
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	uniform mat3 sheenRoughnessMapTransform;
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	uniform mat3 iridescenceMapTransform;
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform mat3 iridescenceThicknessMapTransform;
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SPECULARMAP
	uniform mat3 specularMapTransform;
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	uniform mat3 specularColorMapTransform;
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	uniform mat3 specularIntensityMapTransform;
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,DY=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	vUv = vec3( uv, 1 ).xy;
#endif
#ifdef USE_MAP
	vMapUv = ( mapTransform * vec3( MAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ALPHAMAP
	vAlphaMapUv = ( alphaMapTransform * vec3( ALPHAMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_LIGHTMAP
	vLightMapUv = ( lightMapTransform * vec3( LIGHTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_AOMAP
	vAoMapUv = ( aoMapTransform * vec3( AOMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_BUMPMAP
	vBumpMapUv = ( bumpMapTransform * vec3( BUMPMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_NORMALMAP
	vNormalMapUv = ( normalMapTransform * vec3( NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_DISPLACEMENTMAP
	vDisplacementMapUv = ( displacementMapTransform * vec3( DISPLACEMENTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_EMISSIVEMAP
	vEmissiveMapUv = ( emissiveMapTransform * vec3( EMISSIVEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_METALNESSMAP
	vMetalnessMapUv = ( metalnessMapTransform * vec3( METALNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ROUGHNESSMAP
	vRoughnessMapUv = ( roughnessMapTransform * vec3( ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ANISOTROPYMAP
	vAnisotropyMapUv = ( anisotropyMapTransform * vec3( ANISOTROPYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOATMAP
	vClearcoatMapUv = ( clearcoatMapTransform * vec3( CLEARCOATMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	vClearcoatNormalMapUv = ( clearcoatNormalMapTransform * vec3( CLEARCOAT_NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	vClearcoatRoughnessMapUv = ( clearcoatRoughnessMapTransform * vec3( CLEARCOAT_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCEMAP
	vIridescenceMapUv = ( iridescenceMapTransform * vec3( IRIDESCENCEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	vIridescenceThicknessMapUv = ( iridescenceThicknessMapTransform * vec3( IRIDESCENCE_THICKNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_COLORMAP
	vSheenColorMapUv = ( sheenColorMapTransform * vec3( SHEEN_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	vSheenRoughnessMapUv = ( sheenRoughnessMapTransform * vec3( SHEEN_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULARMAP
	vSpecularMapUv = ( specularMapTransform * vec3( SPECULARMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_COLORMAP
	vSpecularColorMapUv = ( specularColorMapTransform * vec3( SPECULAR_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	vSpecularIntensityMapUv = ( specularIntensityMapTransform * vec3( SPECULAR_INTENSITYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_TRANSMISSIONMAP
	vTransmissionMapUv = ( transmissionMapTransform * vec3( TRANSMISSIONMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_THICKNESSMAP
	vThicknessMapUv = ( thicknessMapTransform * vec3( THICKNESSMAP_UV, 1 ) ).xy;
#endif`,RY=`#if defined( USE_ENVMAP ) || defined( DISTANCE ) || defined ( USE_SHADOWMAP ) || defined ( USE_TRANSMISSION ) || NUM_SPOT_LIGHT_COORDS > 0
	vec4 worldPosition = vec4( transformed, 1.0 );
	#ifdef USE_BATCHING
		worldPosition = batchingMatrix * worldPosition;
	#endif
	#ifdef USE_INSTANCING
		worldPosition = instanceMatrix * worldPosition;
	#endif
	worldPosition = modelMatrix * worldPosition;
#endif`,OY=`varying vec2 vUv;
uniform mat3 uvTransform;
void main() {
	vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	gl_Position = vec4( position.xy, 1.0, 1.0 );
}`,kY=`uniform sampler2D t2D;
uniform float backgroundIntensity;
varying vec2 vUv;
void main() {
	vec4 texColor = texture2D( t2D, vUv );
	#ifdef DECODE_VIDEO_TEXTURE
		texColor = vec4( mix( pow( texColor.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), texColor.rgb * 0.0773993808, vec3( lessThanEqual( texColor.rgb, vec3( 0.04045 ) ) ) ), texColor.w );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,MY=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,LY=`#ifdef ENVMAP_TYPE_CUBE
	uniform samplerCube envMap;
#elif defined( ENVMAP_TYPE_CUBE_UV )
	uniform sampler2D envMap;
#endif
uniform float backgroundBlurriness;
uniform float backgroundIntensity;
uniform mat3 backgroundRotation;
varying vec3 vWorldDirection;
#include <cube_uv_reflection_fragment>
void main() {
	#ifdef ENVMAP_TYPE_CUBE
		vec4 texColor = textureCube( envMap, backgroundRotation * vWorldDirection );
	#elif defined( ENVMAP_TYPE_CUBE_UV )
		vec4 texColor = textureCubeUV( envMap, backgroundRotation * vWorldDirection, backgroundBlurriness );
	#else
		vec4 texColor = vec4( 0.0, 0.0, 0.0, 1.0 );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,VY=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,BY=`uniform samplerCube tCube;
uniform float tFlip;
uniform float opacity;
varying vec3 vWorldDirection;
void main() {
	vec4 texColor = textureCube( tCube, vec3( tFlip * vWorldDirection.x, vWorldDirection.yz ) );
	gl_FragColor = texColor;
	gl_FragColor.a *= opacity;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,zY=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
varying vec2 vHighPrecisionZW;
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vHighPrecisionZW = gl_Position.zw;
}`,IY=`#if DEPTH_PACKING == 3200
	uniform float opacity;
#endif
#include <common>
#include <packing>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
varying vec2 vHighPrecisionZW;
void main() {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#if DEPTH_PACKING == 3200
		diffuseColor.a = opacity;
	#endif
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <logdepthbuf_fragment>
	#ifdef USE_REVERSED_DEPTH_BUFFER
		float fragCoordZ = vHighPrecisionZW[ 0 ] / vHighPrecisionZW[ 1 ];
	#else
		float fragCoordZ = 0.5 * vHighPrecisionZW[ 0 ] / vHighPrecisionZW[ 1 ] + 0.5;
	#endif
	#if DEPTH_PACKING == 3200
		gl_FragColor = vec4( vec3( 1.0 - fragCoordZ ), opacity );
	#elif DEPTH_PACKING == 3201
		gl_FragColor = packDepthToRGBA( fragCoordZ );
	#elif DEPTH_PACKING == 3202
		gl_FragColor = vec4( packDepthToRGB( fragCoordZ ), 1.0 );
	#elif DEPTH_PACKING == 3203
		gl_FragColor = vec4( packDepthToRG( fragCoordZ ), 0.0, 1.0 );
	#endif
}`,AY=`#define DISTANCE
varying vec3 vWorldPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <worldpos_vertex>
	#include <clipping_planes_vertex>
	vWorldPosition = worldPosition.xyz;
}`,wY=`#define DISTANCE
uniform vec3 referencePosition;
uniform float nearDistance;
uniform float farDistance;
varying vec3 vWorldPosition;
#include <common>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	float dist = length( vWorldPosition - referencePosition );
	dist = ( dist - nearDistance ) / ( farDistance - nearDistance );
	dist = saturate( dist );
	gl_FragColor = vec4( dist, 0.0, 0.0, 1.0 );
}`,CY=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
}`,_Y=`uniform sampler2D tEquirect;
varying vec3 vWorldDirection;
#include <common>
void main() {
	vec3 direction = normalize( vWorldDirection );
	vec2 sampleUV = equirectUv( direction );
	gl_FragColor = texture2D( tEquirect, sampleUV );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,PY=`uniform float scale;
attribute float lineDistance;
varying float vLineDistance;
#include <common>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	vLineDistance = scale * lineDistance;
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,TY=`uniform vec3 diffuse;
uniform float opacity;
uniform float dashSize;
uniform float totalSize;
varying float vLineDistance;
#include <common>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	if ( mod( vLineDistance, totalSize ) > dashSize ) {
		discard;
	}
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,SY=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#if defined ( USE_ENVMAP ) || defined ( USE_SKINNING )
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinbase_vertex>
		#include <skinnormal_vertex>
		#include <defaultnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <fog_vertex>
}`,jY=`uniform vec3 diffuse;
uniform float opacity;
#ifndef FLAT_SHADED
	varying vec3 vNormal;
#endif
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		reflectedLight.indirectDiffuse += lightMapTexel.rgb * lightMapIntensity * RECIPROCAL_PI;
	#else
		reflectedLight.indirectDiffuse += vec3( 1.0 );
	#endif
	#include <aomap_fragment>
	reflectedLight.indirectDiffuse *= diffuseColor.rgb;
	vec3 outgoingLight = reflectedLight.indirectDiffuse;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,yY=`#define LAMBERT
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,fY=`#define LAMBERT
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <cube_uv_reflection_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <envmap_physical_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_lambert_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_lambert_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,vY=`#define MATCAP
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <displacementmap_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
	vViewPosition = - mvPosition.xyz;
}`,bY=`#define MATCAP
uniform vec3 diffuse;
uniform float opacity;
uniform sampler2D matcap;
varying vec3 vViewPosition;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	vec3 viewDir = normalize( vViewPosition );
	vec3 x = normalize( vec3( viewDir.z, 0.0, - viewDir.x ) );
	vec3 y = cross( viewDir, x );
	vec2 uv = vec2( dot( x, normal ), dot( y, normal ) ) * 0.495 + 0.5;
	#ifdef USE_MATCAP
		vec4 matcapColor = texture2D( matcap, uv );
	#else
		vec4 matcapColor = vec4( vec3( mix( 0.2, 0.8, uv.y ) ), 1.0 );
	#endif
	vec3 outgoingLight = diffuseColor.rgb * matcapColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,hY=`#define NORMAL
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	vViewPosition = - mvPosition.xyz;
#endif
}`,xY=`#define NORMAL
uniform float opacity;
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <uv_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( 0.0, 0.0, 0.0, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	gl_FragColor = vec4( normalize( normal ) * 0.5 + 0.5, diffuseColor.a );
	#ifdef OPAQUE
		gl_FragColor.a = 1.0;
	#endif
}`,gY=`#define PHONG
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,pY=`#define PHONG
uniform vec3 diffuse;
uniform vec3 emissive;
uniform vec3 specular;
uniform float shininess;
uniform float opacity;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <cube_uv_reflection_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <envmap_physical_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_phong_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_phong_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + reflectedLight.directSpecular + reflectedLight.indirectSpecular + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,mY=`#define STANDARD
varying vec3 vViewPosition;
#ifdef USE_TRANSMISSION
	varying vec3 vWorldPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
#ifdef USE_TRANSMISSION
	vWorldPosition = worldPosition.xyz;
#endif
}`,dY=`#define STANDARD
#ifdef PHYSICAL
	#define IOR
	#define USE_SPECULAR
#endif
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float roughness;
uniform float metalness;
uniform float opacity;
#ifdef IOR
	uniform float ior;
#endif
#ifdef USE_SPECULAR
	uniform float specularIntensity;
	uniform vec3 specularColor;
	#ifdef USE_SPECULAR_COLORMAP
		uniform sampler2D specularColorMap;
	#endif
	#ifdef USE_SPECULAR_INTENSITYMAP
		uniform sampler2D specularIntensityMap;
	#endif
#endif
#ifdef USE_CLEARCOAT
	uniform float clearcoat;
	uniform float clearcoatRoughness;
#endif
#ifdef USE_DISPERSION
	uniform float dispersion;
#endif
#ifdef USE_IRIDESCENCE
	uniform float iridescence;
	uniform float iridescenceIOR;
	uniform float iridescenceThicknessMinimum;
	uniform float iridescenceThicknessMaximum;
#endif
#ifdef USE_SHEEN
	uniform vec3 sheenColor;
	uniform float sheenRoughness;
	#ifdef USE_SHEEN_COLORMAP
		uniform sampler2D sheenColorMap;
	#endif
	#ifdef USE_SHEEN_ROUGHNESSMAP
		uniform sampler2D sheenRoughnessMap;
	#endif
#endif
#ifdef USE_ANISOTROPY
	uniform vec2 anisotropyVector;
	#ifdef USE_ANISOTROPYMAP
		uniform sampler2D anisotropyMap;
	#endif
#endif
varying vec3 vViewPosition;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <iridescence_fragment>
#include <cube_uv_reflection_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_physical_pars_fragment>
#include <fog_pars_fragment>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_physical_pars_fragment>
#include <transmission_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <clearcoat_pars_fragment>
#include <iridescence_pars_fragment>
#include <roughnessmap_pars_fragment>
#include <metalnessmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <roughnessmap_fragment>
	#include <metalnessmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <clearcoat_normal_fragment_begin>
	#include <clearcoat_normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_physical_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 totalDiffuse = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse;
	vec3 totalSpecular = reflectedLight.directSpecular + reflectedLight.indirectSpecular;
	#include <transmission_fragment>
	vec3 outgoingLight = totalDiffuse + totalSpecular + totalEmissiveRadiance;
	#ifdef USE_SHEEN
 
		outgoingLight = outgoingLight + sheenSpecularDirect + sheenSpecularIndirect;
 
 	#endif
	#ifdef USE_CLEARCOAT
		float dotNVcc = saturate( dot( geometryClearcoatNormal, geometryViewDir ) );
		vec3 Fcc = F_Schlick( material.clearcoatF0, material.clearcoatF90, dotNVcc );
		outgoingLight = outgoingLight * ( 1.0 - material.clearcoat * Fcc ) + ( clearcoatSpecularDirect + clearcoatSpecularIndirect ) * material.clearcoat;
	#endif
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,lY=`#define TOON
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,uY=`#define TOON
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <gradientmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_toon_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_toon_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,cY=`uniform float size;
uniform float scale;
#include <common>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
#ifdef USE_POINTS_UV
	varying vec2 vUv;
	uniform mat3 uvTransform;
#endif
void main() {
	#ifdef USE_POINTS_UV
		vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	#endif
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	gl_PointSize = size;
	#ifdef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) gl_PointSize *= ( scale / - mvPosition.z );
	#endif
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <fog_vertex>
}`,nY=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <color_pars_fragment>
#include <map_particle_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_particle_fragment>
	#include <color_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,sY=`#include <common>
#include <batching_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <shadowmap_pars_vertex>
void main() {
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,iY=`uniform vec3 color;
uniform float opacity;
#include <common>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <logdepthbuf_pars_fragment>
#include <shadowmap_pars_fragment>
#include <shadowmask_pars_fragment>
void main() {
	#include <logdepthbuf_fragment>
	gl_FragColor = vec4( color, opacity * ( 1.0 - getShadowMask() ) );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,oY=`uniform float rotation;
uniform vec2 center;
#include <common>
#include <uv_pars_vertex>
#include <fog_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	vec4 mvPosition = modelViewMatrix[ 3 ];
	vec2 scale = vec2( length( modelMatrix[ 0 ].xyz ), length( modelMatrix[ 1 ].xyz ) );
	#ifndef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) scale *= - mvPosition.z;
	#endif
	vec2 alignedPosition = ( position.xy - ( center - vec2( 0.5 ) ) ) * scale;
	vec2 rotatedPosition;
	rotatedPosition.x = cos( rotation ) * alignedPosition.x - sin( rotation ) * alignedPosition.y;
	rotatedPosition.y = sin( rotation ) * alignedPosition.x + cos( rotation ) * alignedPosition.y;
	mvPosition.xy += rotatedPosition;
	gl_Position = projectionMatrix * mvPosition;
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,aY=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
}`,j0={alphahash_fragment:OK,alphahash_pars_fragment:kK,alphamap_fragment:MK,alphamap_pars_fragment:LK,alphatest_fragment:VK,alphatest_pars_fragment:BK,aomap_fragment:zK,aomap_pars_fragment:IK,batching_pars_vertex:AK,batching_vertex:wK,begin_vertex:CK,beginnormal_vertex:_K,bsdfs:PK,iridescence_fragment:TK,bumpmap_pars_fragment:SK,clipping_planes_fragment:jK,clipping_planes_pars_fragment:yK,clipping_planes_pars_vertex:fK,clipping_planes_vertex:vK,color_fragment:bK,color_pars_fragment:hK,color_pars_vertex:xK,color_vertex:gK,common:pK,cube_uv_reflection_fragment:mK,defaultnormal_vertex:dK,displacementmap_pars_vertex:lK,displacementmap_vertex:uK,emissivemap_fragment:cK,emissivemap_pars_fragment:nK,colorspace_fragment:sK,colorspace_pars_fragment:iK,envmap_fragment:oK,envmap_common_pars_fragment:aK,envmap_pars_fragment:rK,envmap_pars_vertex:tK,envmap_physical_pars_fragment:UH,envmap_vertex:eK,fog_vertex:JH,fog_pars_vertex:QH,fog_fragment:$H,fog_pars_fragment:ZH,gradientmap_pars_fragment:WH,lightmap_pars_fragment:KH,lights_lambert_fragment:HH,lights_lambert_pars_fragment:YH,lights_pars_begin:XH,lights_toon_fragment:GH,lights_toon_pars_fragment:EH,lights_phong_fragment:NH,lights_phong_pars_fragment:qH,lights_physical_fragment:FH,lights_physical_pars_fragment:DH,lights_fragment_begin:RH,lights_fragment_maps:OH,lights_fragment_end:kH,lightprobes_pars_fragment:MH,logdepthbuf_fragment:LH,logdepthbuf_pars_fragment:VH,logdepthbuf_pars_vertex:BH,logdepthbuf_vertex:zH,map_fragment:IH,map_pars_fragment:AH,map_particle_fragment:wH,map_particle_pars_fragment:CH,metalnessmap_fragment:_H,metalnessmap_pars_fragment:PH,morphinstance_vertex:TH,morphcolor_vertex:SH,morphnormal_vertex:jH,morphtarget_pars_vertex:yH,morphtarget_vertex:fH,normal_fragment_begin:vH,normal_fragment_maps:bH,normal_pars_fragment:hH,normal_pars_vertex:xH,normal_vertex:gH,normalmap_pars_fragment:pH,clearcoat_normal_fragment_begin:mH,clearcoat_normal_fragment_maps:dH,clearcoat_pars_fragment:lH,iridescence_pars_fragment:uH,opaque_fragment:cH,packing:nH,premultiplied_alpha_fragment:sH,project_vertex:iH,dithering_fragment:oH,dithering_pars_fragment:aH,roughnessmap_fragment:rH,roughnessmap_pars_fragment:tH,shadowmap_pars_fragment:eH,shadowmap_pars_vertex:JY,shadowmap_vertex:QY,shadowmask_pars_fragment:$Y,skinbase_vertex:ZY,skinning_pars_vertex:WY,skinning_vertex:KY,skinnormal_vertex:HY,specularmap_fragment:YY,specularmap_pars_fragment:XY,tonemapping_fragment:UY,tonemapping_pars_fragment:GY,transmission_fragment:EY,transmission_pars_fragment:NY,uv_pars_fragment:qY,uv_pars_vertex:FY,uv_vertex:DY,worldpos_vertex:RY,background_vert:OY,background_frag:kY,backgroundCube_vert:MY,backgroundCube_frag:LY,cube_vert:VY,cube_frag:BY,depth_vert:zY,depth_frag:IY,distance_vert:AY,distance_frag:wY,equirect_vert:CY,equirect_frag:_Y,linedashed_vert:PY,linedashed_frag:TY,meshbasic_vert:SY,meshbasic_frag:jY,meshlambert_vert:yY,meshlambert_frag:fY,meshmatcap_vert:vY,meshmatcap_frag:bY,meshnormal_vert:hY,meshnormal_frag:xY,meshphong_vert:gY,meshphong_frag:pY,meshphysical_vert:mY,meshphysical_frag:dY,meshtoon_vert:lY,meshtoon_frag:uY,points_vert:cY,points_frag:nY,shadow_vert:sY,shadow_frag:iY,sprite_vert:oY,sprite_frag:aY},U0={common:{diffuse:{value:new g0(16777215)},opacity:{value:1},map:{value:null},mapTransform:{value:new P0},alphaMap:{value:null},alphaMapTransform:{value:new P0},alphaTest:{value:0}},specularmap:{specularMap:{value:null},specularMapTransform:{value:new P0}},envmap:{envMap:{value:null},envMapRotation:{value:new P0},reflectivity:{value:1},ior:{value:1.5},refractionRatio:{value:0.98},dfgLUT:{value:null}},aomap:{aoMap:{value:null},aoMapIntensity:{value:1},aoMapTransform:{value:new P0}},lightmap:{lightMap:{value:null},lightMapIntensity:{value:1},lightMapTransform:{value:new P0}},bumpmap:{bumpMap:{value:null},bumpMapTransform:{value:new P0},bumpScale:{value:1}},normalmap:{normalMap:{value:null},normalMapTransform:{value:new P0},normalScale:{value:new u0(1,1)}},displacementmap:{displacementMap:{value:null},displacementMapTransform:{value:new P0},displacementScale:{value:1},displacementBias:{value:0}},emissivemap:{emissiveMap:{value:null},emissiveMapTransform:{value:new P0}},metalnessmap:{metalnessMap:{value:null},metalnessMapTransform:{value:new P0}},roughnessmap:{roughnessMap:{value:null},roughnessMapTransform:{value:new P0}},gradientmap:{gradientMap:{value:null}},fog:{fogDensity:{value:0.00025},fogNear:{value:1},fogFar:{value:2000},fogColor:{value:new g0(16777215)}},lights:{ambientLightColor:{value:[]},lightProbe:{value:[]},directionalLights:{value:[],properties:{direction:{},color:{}}},directionalLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},directionalShadowMatrix:{value:[]},spotLights:{value:[],properties:{color:{},position:{},direction:{},distance:{},coneCos:{},penumbraCos:{},decay:{}}},spotLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},spotLightMap:{value:[]},spotLightMatrix:{value:[]},pointLights:{value:[],properties:{color:{},position:{},decay:{},distance:{}}},pointLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{},shadowCameraNear:{},shadowCameraFar:{}}},pointShadowMatrix:{value:[]},hemisphereLights:{value:[],properties:{direction:{},skyColor:{},groundColor:{}}},rectAreaLights:{value:[],properties:{color:{},position:{},width:{},height:{}}},ltc_1:{value:null},ltc_2:{value:null},probesSH:{value:null},probesMin:{value:new b},probesMax:{value:new b},probesResolution:{value:new b}},points:{diffuse:{value:new g0(16777215)},opacity:{value:1},size:{value:1},scale:{value:1},map:{value:null},alphaMap:{value:null},alphaMapTransform:{value:new P0},alphaTest:{value:0},uvTransform:{value:new P0}},sprite:{diffuse:{value:new g0(16777215)},opacity:{value:1},center:{value:new u0(0.5,0.5)},rotation:{value:0},map:{value:null},mapTransform:{value:new P0},alphaMap:{value:null},alphaMapTransform:{value:new P0},alphaTest:{value:0}}},Q9={basic:{uniforms:zJ([U0.common,U0.specularmap,U0.envmap,U0.aomap,U0.lightmap,U0.fog]),vertexShader:j0.meshbasic_vert,fragmentShader:j0.meshbasic_frag},lambert:{uniforms:zJ([U0.common,U0.specularmap,U0.envmap,U0.aomap,U0.lightmap,U0.emissivemap,U0.bumpmap,U0.normalmap,U0.displacementmap,U0.fog,U0.lights,{emissive:{value:new g0(0)},envMapIntensity:{value:1}}]),vertexShader:j0.meshlambert_vert,fragmentShader:j0.meshlambert_frag},phong:{uniforms:zJ([U0.common,U0.specularmap,U0.envmap,U0.aomap,U0.lightmap,U0.emissivemap,U0.bumpmap,U0.normalmap,U0.displacementmap,U0.fog,U0.lights,{emissive:{value:new g0(0)},specular:{value:new g0(1118481)},shininess:{value:30},envMapIntensity:{value:1}}]),vertexShader:j0.meshphong_vert,fragmentShader:j0.meshphong_frag},standard:{uniforms:zJ([U0.common,U0.envmap,U0.aomap,U0.lightmap,U0.emissivemap,U0.bumpmap,U0.normalmap,U0.displacementmap,U0.roughnessmap,U0.metalnessmap,U0.fog,U0.lights,{emissive:{value:new g0(0)},roughness:{value:1},metalness:{value:0},envMapIntensity:{value:1}}]),vertexShader:j0.meshphysical_vert,fragmentShader:j0.meshphysical_frag},toon:{uniforms:zJ([U0.common,U0.aomap,U0.lightmap,U0.emissivemap,U0.bumpmap,U0.normalmap,U0.displacementmap,U0.gradientmap,U0.fog,U0.lights,{emissive:{value:new g0(0)}}]),vertexShader:j0.meshtoon_vert,fragmentShader:j0.meshtoon_frag},matcap:{uniforms:zJ([U0.common,U0.bumpmap,U0.normalmap,U0.displacementmap,U0.fog,{matcap:{value:null}}]),vertexShader:j0.meshmatcap_vert,fragmentShader:j0.meshmatcap_frag},points:{uniforms:zJ([U0.points,U0.fog]),vertexShader:j0.points_vert,fragmentShader:j0.points_frag},dashed:{uniforms:zJ([U0.common,U0.fog,{scale:{value:1},dashSize:{value:1},totalSize:{value:2}}]),vertexShader:j0.linedashed_vert,fragmentShader:j0.linedashed_frag},depth:{uniforms:zJ([U0.common,U0.displacementmap]),vertexShader:j0.depth_vert,fragmentShader:j0.depth_frag},normal:{uniforms:zJ([U0.common,U0.bumpmap,U0.normalmap,U0.displacementmap,{opacity:{value:1}}]),vertexShader:j0.meshnormal_vert,fragmentShader:j0.meshnormal_frag},sprite:{uniforms:zJ([U0.sprite,U0.fog]),vertexShader:j0.sprite_vert,fragmentShader:j0.sprite_frag},background:{uniforms:{uvTransform:{value:new P0},t2D:{value:null},backgroundIntensity:{value:1}},vertexShader:j0.background_vert,fragmentShader:j0.background_frag},backgroundCube:{uniforms:{envMap:{value:null},backgroundBlurriness:{value:0},backgroundIntensity:{value:1},backgroundRotation:{value:new P0}},vertexShader:j0.backgroundCube_vert,fragmentShader:j0.backgroundCube_frag},cube:{uniforms:{tCube:{value:null},tFlip:{value:-1},opacity:{value:1}},vertexShader:j0.cube_vert,fragmentShader:j0.cube_frag},equirect:{uniforms:{tEquirect:{value:null}},vertexShader:j0.equirect_vert,fragmentShader:j0.equirect_frag},distance:{uniforms:zJ([U0.common,U0.displacementmap,{referencePosition:{value:new b},nearDistance:{value:1},farDistance:{value:1000}}]),vertexShader:j0.distance_vert,fragmentShader:j0.distance_frag},shadow:{uniforms:zJ([U0.lights,U0.fog,{color:{value:new g0(0)},opacity:{value:1}}]),vertexShader:j0.shadow_vert,fragmentShader:j0.shadow_frag}};Q9.physical={uniforms:zJ([Q9.standard.uniforms,{clearcoat:{value:0},clearcoatMap:{value:null},clearcoatMapTransform:{value:new P0},clearcoatNormalMap:{value:null},clearcoatNormalMapTransform:{value:new P0},clearcoatNormalScale:{value:new u0(1,1)},clearcoatRoughness:{value:0},clearcoatRoughnessMap:{value:null},clearcoatRoughnessMapTransform:{value:new P0},dispersion:{value:0},iridescence:{value:0},iridescenceMap:{value:null},iridescenceMapTransform:{value:new P0},iridescenceIOR:{value:1.3},iridescenceThicknessMinimum:{value:100},iridescenceThicknessMaximum:{value:400},iridescenceThicknessMap:{value:null},iridescenceThicknessMapTransform:{value:new P0},sheen:{value:0},sheenColor:{value:new g0(0)},sheenColorMap:{value:null},sheenColorMapTransform:{value:new P0},sheenRoughness:{value:1},sheenRoughnessMap:{value:null},sheenRoughnessMapTransform:{value:new P0},transmission:{value:0},transmissionMap:{value:null},transmissionMapTransform:{value:new P0},transmissionSamplerSize:{value:new u0},transmissionSamplerMap:{value:null},thickness:{value:0},thicknessMap:{value:null},thicknessMapTransform:{value:new P0},attenuationDistance:{value:0},attenuationColor:{value:new g0(0)},specularColor:{value:new g0(1,1,1)},specularColorMap:{value:null},specularColorMapTransform:{value:new P0},specularIntensity:{value:1},specularIntensityMap:{value:null},specularIntensityMapTransform:{value:new P0},anisotropyVector:{value:new u0},anisotropyMap:{value:null},anisotropyMapTransform:{value:new P0}}]),vertexShader:j0.meshphysical_vert,fragmentShader:j0.meshphysical_frag};var x6={r:0,b:0,g:0},rY=new WJ,XW=new P0;XW.set(-1,0,0,0,1,0,0,0,1);function tY(J,Q,$,Z,W,K){let H=new g0(0),Y=W===!0?0:1,X,U,E=null,N=0,G=null;function D(_){let w=_.isScene===!0?_.background:null;if(w&&w.isTexture){let V=_.backgroundBlurriness>0;w=Q.get(w,V)}return w}function M(_){let w=!1,V=D(_);if(V===null)F(H,Y);else if(V&&V.isColor)F(V,1),w=!0;let A=J.xr.getEnvironmentBlendMode();if(A==="additive")$.buffers.color.setClear(0,0,0,1,K);else if(A==="alpha-blend")$.buffers.color.setClear(0,0,0,0,K);if(J.autoClear||w)$.buffers.depth.setTest(!0),$.buffers.depth.setMask(!0),$.buffers.color.setMask(!0),J.clear(J.autoClearColor,J.autoClearDepth,J.autoClearStencil)}function z(_,w){let V=D(w);if(V&&(V.isCubeTexture||V.mapping===_8)){if(U===void 0)U=new sJ(new O8(1,1,1),new gJ({name:"BackgroundCubeMaterial",uniforms:u9(Q9.backgroundCube.uniforms),vertexShader:Q9.backgroundCube.vertexShader,fragmentShader:Q9.backgroundCube.fragmentShader,side:CJ,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),U.geometry.deleteAttribute("normal"),U.geometry.deleteAttribute("uv"),U.onBeforeRender=function(A,I,P){this.matrixWorld.copyPosition(P.matrixWorld)},Object.defineProperty(U.material,"envMap",{get:function(){return this.uniforms.envMap.value}}),Z.update(U);if(U.material.uniforms.envMap.value=V,U.material.uniforms.backgroundBlurriness.value=w.backgroundBlurriness,U.material.uniforms.backgroundIntensity.value=w.backgroundIntensity,U.material.uniforms.backgroundRotation.value.setFromMatrix4(rY.makeRotationFromEuler(w.backgroundRotation)).transpose(),V.isCubeTexture&&V.isRenderTargetTexture===!1)U.material.uniforms.backgroundRotation.value.premultiply(XW);if(U.material.toneMapped=h0.getTransfer(V.colorSpace)!==r0,E!==V||N!==V.version||G!==J.toneMapping)U.material.needsUpdate=!0,E=V,N=V.version,G=J.toneMapping;U.layers.enableAll(),_.unshift(U,U.geometry,U.material,0,0,null)}else if(V&&V.isTexture){if(X===void 0)X=new sJ(new v8(2,2),new gJ({name:"BackgroundMaterial",uniforms:u9(Q9.background.uniforms),vertexShader:Q9.background.vertexShader,fragmentShader:Q9.background.fragmentShader,side:N8,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),X.geometry.deleteAttribute("normal"),Object.defineProperty(X.material,"map",{get:function(){return this.uniforms.t2D.value}}),Z.update(X);if(X.material.uniforms.t2D.value=V,X.material.uniforms.backgroundIntensity.value=w.backgroundIntensity,X.material.toneMapped=h0.getTransfer(V.colorSpace)!==r0,V.matrixAutoUpdate===!0)V.updateMatrix();if(X.material.uniforms.uvTransform.value.copy(V.matrix),E!==V||N!==V.version||G!==J.toneMapping)X.material.needsUpdate=!0,E=V,N=V.version,G=J.toneMapping;X.layers.enableAll(),_.unshift(X,X.geometry,X.material,0,0,null)}}function F(_,w){_.getRGB(x6,LQ(J)),$.buffers.color.setClear(x6.r,x6.g,x6.b,w,K)}function q(){if(U!==void 0)U.geometry.dispose(),U.material.dispose(),U=void 0;if(X!==void 0)X.geometry.dispose(),X.material.dispose(),X=void 0}return{getClearColor:function(){return H},setClearColor:function(_,w=1){H.set(_),Y=w,F(H,Y)},getClearAlpha:function(){return Y},setClearAlpha:function(_){Y=_,F(H,Y)},render:M,addToRenderList:z,dispose:q}}function eY(J,Q){let $=J.getParameter(J.MAX_VERTEX_ATTRIBS),Z={},W=G(null),K=W,H=!1;function Y(C,m,o,p,n){let u=!1,h=N(C,p,o,m);if(K!==h)K=h,U(K.object);if(u=D(C,p,o,n),u)M(C,p,o,n);if(n!==null)Q.update(n,J.ELEMENT_ARRAY_BUFFER);if(u||H){if(H=!1,V(C,m,o,p),n!==null)J.bindBuffer(J.ELEMENT_ARRAY_BUFFER,Q.get(n).buffer)}}function X(){return J.createVertexArray()}function U(C){return J.bindVertexArray(C)}function E(C){return J.deleteVertexArray(C)}function N(C,m,o,p){let n=p.wireframe===!0,u=Z[m.id];if(u===void 0)u={},Z[m.id]=u;let h=C.isInstancedMesh===!0?C.id:0,t=u[h];if(t===void 0)t={},u[h]=t;let e=t[o.id];if(e===void 0)e={},t[o.id]=e;let H0=e[n];if(H0===void 0)H0=G(X()),e[n]=H0;return H0}function G(C){let m=[],o=[],p=[];for(let n=0;n<$;n++)m[n]=0,o[n]=0,p[n]=0;return{geometry:null,program:null,wireframe:!1,newAttributes:m,enabledAttributes:o,attributeDivisors:p,object:C,attributes:{},index:null}}function D(C,m,o,p){let n=K.attributes,u=m.attributes,h=0,t=o.getAttributes();for(let e in t)if(t[e].location>=0){let M0=n[e],k0=u[e];if(k0===void 0){if(e==="instanceMatrix"&&C.instanceMatrix)k0=C.instanceMatrix;if(e==="instanceColor"&&C.instanceColor)k0=C.instanceColor}if(M0===void 0)return!0;if(M0.attribute!==k0)return!0;if(k0&&M0.data!==k0.data)return!0;h++}if(K.attributesNum!==h)return!0;if(K.index!==p)return!0;return!1}function M(C,m,o,p){let n={},u=m.attributes,h=0,t=o.getAttributes();for(let e in t)if(t[e].location>=0){let M0=u[e];if(M0===void 0){if(e==="instanceMatrix"&&C.instanceMatrix)M0=C.instanceMatrix;if(e==="instanceColor"&&C.instanceColor)M0=C.instanceColor}let k0={};if(k0.attribute=M0,M0&&M0.data)k0.data=M0.data;n[e]=k0,h++}K.attributes=n,K.attributesNum=h,K.index=p}function z(){let C=K.newAttributes;for(let m=0,o=C.length;m<o;m++)C[m]=0}function F(C){q(C,0)}function q(C,m){let{newAttributes:o,enabledAttributes:p,attributeDivisors:n}=K;if(o[C]=1,p[C]===0)J.enableVertexAttribArray(C),p[C]=1;if(n[C]!==m)J.vertexAttribDivisor(C,m),n[C]=m}function _(){let{newAttributes:C,enabledAttributes:m}=K;for(let o=0,p=m.length;o<p;o++)if(m[o]!==C[o])J.disableVertexAttribArray(o),m[o]=0}function w(C,m,o,p,n,u,h){if(h===!0)J.vertexAttribIPointer(C,m,o,n,u);else J.vertexAttribPointer(C,m,o,p,n,u)}function V(C,m,o,p){z();let n=p.attributes,u=o.getAttributes(),h=m.defaultAttributeValues;for(let t in u){let e=u[t];if(e.location>=0){let H0=n[t];if(H0===void 0){if(t==="instanceMatrix"&&C.instanceMatrix)H0=C.instanceMatrix;if(t==="instanceColor"&&C.instanceColor)H0=C.instanceColor}if(H0!==void 0){let{normalized:M0,itemSize:k0}=H0,ZJ=Q.get(H0);if(ZJ===void 0)continue;let{buffer:i0,type:i,bytesPerElement:Z0}=ZJ,F0=i===J.INT||i===J.UNSIGNED_INT||H0.gpuType===C7;if(H0.isInterleavedBufferAttribute){let D0=H0.data,w0=D0.stride,p0=H0.offset;if(D0.isInstancedInterleavedBuffer){for(let f0=0;f0<e.locationSize;f0++)q(e.location+f0,D0.meshPerAttribute);if(C.isInstancedMesh!==!0&&p._maxInstanceCount===void 0)p._maxInstanceCount=D0.meshPerAttribute*D0.count}else for(let f0=0;f0<e.locationSize;f0++)F(e.location+f0);J.bindBuffer(J.ARRAY_BUFFER,i0);for(let f0=0;f0<e.locationSize;f0++)w(e.location+f0,k0/e.locationSize,i,M0,w0*Z0,(p0+k0/e.locationSize*f0)*Z0,F0)}else{if(H0.isInstancedBufferAttribute){for(let D0=0;D0<e.locationSize;D0++)q(e.location+D0,H0.meshPerAttribute);if(C.isInstancedMesh!==!0&&p._maxInstanceCount===void 0)p._maxInstanceCount=H0.meshPerAttribute*H0.count}else for(let D0=0;D0<e.locationSize;D0++)F(e.location+D0);J.bindBuffer(J.ARRAY_BUFFER,i0);for(let D0=0;D0<e.locationSize;D0++)w(e.location+D0,k0/e.locationSize,i,M0,k0*Z0,k0/e.locationSize*D0*Z0,F0)}}else if(h!==void 0){let M0=h[t];if(M0!==void 0)switch(M0.length){case 2:J.vertexAttrib2fv(e.location,M0);break;case 3:J.vertexAttrib3fv(e.location,M0);break;case 4:J.vertexAttrib4fv(e.location,M0);break;default:J.vertexAttrib1fv(e.location,M0)}}}}_()}function A(){B();for(let C in Z){let m=Z[C];for(let o in m){let p=m[o];for(let n in p){let u=p[n];for(let h in u)E(u[h].object),delete u[h];delete p[n]}}delete Z[C]}}function I(C){if(Z[C.id]===void 0)return;let m=Z[C.id];for(let o in m){let p=m[o];for(let n in p){let u=p[n];for(let h in u)E(u[h].object),delete u[h];delete p[n]}}delete Z[C.id]}function P(C){for(let m in Z){let o=Z[m];for(let p in o){let n=o[p];if(n[C.id]===void 0)continue;let u=n[C.id];for(let h in u)E(u[h].object),delete u[h];delete n[C.id]}}}function O(C){for(let m in Z){let o=Z[m],p=C.isInstancedMesh===!0?C.id:0,n=o[p];if(n===void 0)continue;for(let u in n){let h=n[u];for(let t in h)E(h[t].object),delete h[t];delete n[u]}if(delete o[p],Object.keys(o).length===0)delete Z[m]}}function B(){if(l(),H=!0,K===W)return;K=W,U(K.object)}function l(){W.geometry=null,W.program=null,W.wireframe=!1}return{setup:Y,reset:B,resetDefaultState:l,dispose:A,releaseStatesOfGeometry:I,releaseStatesOfObject:O,releaseStatesOfProgram:P,initAttributes:z,enableAttribute:F,disableUnusedAttributes:_}}function JX(J,Q,$){let Z;function W(X){Z=X}function K(X,U){J.drawArrays(Z,X,U),$.update(U,Z,1)}function H(X,U,E){if(E===0)return;J.drawArraysInstanced(Z,X,U,E),$.update(U,Z,E)}function Y(X,U,E){if(E===0)return;Q.get("WEBGL_multi_draw").multiDrawArraysWEBGL(Z,X,0,U,0,E);let G=0;for(let D=0;D<E;D++)G+=U[D];$.update(G,Z,1)}this.setMode=W,this.render=K,this.renderInstances=H,this.renderMultiDraw=Y}function QX(J,Q,$,Z){let W;function K(){if(W!==void 0)return W;if(Q.has("EXT_texture_filter_anisotropic")===!0){let P=Q.get("EXT_texture_filter_anisotropic");W=J.getParameter(P.MAX_TEXTURE_MAX_ANISOTROPY_EXT)}else W=0;return W}function H(P){if(P!==eJ&&Z.convert(P)!==J.getParameter(J.IMPLEMENTATION_COLOR_READ_FORMAT))return!1;return!0}function Y(P){let O=P===E9&&(Q.has("EXT_color_buffer_half_float")||Q.has("EXT_color_buffer_float"));if(P!==nJ&&Z.convert(P)!==J.getParameter(J.IMPLEMENTATION_COLOR_READ_TYPE)&&P!==G9&&!O)return!1;return!0}function X(P){if(P==="highp"){if(J.getShaderPrecisionFormat(J.VERTEX_SHADER,J.HIGH_FLOAT).precision>0&&J.getShaderPrecisionFormat(J.FRAGMENT_SHADER,J.HIGH_FLOAT).precision>0)return"highp";P="mediump"}if(P==="mediump"){if(J.getShaderPrecisionFormat(J.VERTEX_SHADER,J.MEDIUM_FLOAT).precision>0&&J.getShaderPrecisionFormat(J.FRAGMENT_SHADER,J.MEDIUM_FLOAT).precision>0)return"mediump"}return"lowp"}let U=$.precision!==void 0?$.precision:"highp",E=X(U);if(E!==U)C0("WebGLRenderer:",U,"not supported, using",E,"instead."),U=E;let N=$.logarithmicDepthBuffer===!0,G=$.reversedDepthBuffer===!0&&Q.has("EXT_clip_control");if($.reversedDepthBuffer===!0&&G===!1)C0("WebGLRenderer: Unable to use reversed depth buffer due to missing EXT_clip_control extension. Fallback to default depth buffer.");let D=J.getParameter(J.MAX_TEXTURE_IMAGE_UNITS),M=J.getParameter(J.MAX_VERTEX_TEXTURE_IMAGE_UNITS),z=J.getParameter(J.MAX_TEXTURE_SIZE),F=J.getParameter(J.MAX_CUBE_MAP_TEXTURE_SIZE),q=J.getParameter(J.MAX_VERTEX_ATTRIBS),_=J.getParameter(J.MAX_VERTEX_UNIFORM_VECTORS),w=J.getParameter(J.MAX_VARYING_VECTORS),V=J.getParameter(J.MAX_FRAGMENT_UNIFORM_VECTORS),A=J.getParameter(J.MAX_SAMPLES),I=J.getParameter(J.SAMPLES);return{isWebGL2:!0,getMaxAnisotropy:K,getMaxPrecision:X,textureFormatReadable:H,textureTypeReadable:Y,precision:U,logarithmicDepthBuffer:N,reversedDepthBuffer:G,maxTextures:D,maxVertexTextures:M,maxTextureSize:z,maxCubemapSize:F,maxAttributes:q,maxVertexUniforms:_,maxVaryings:w,maxFragmentUniforms:V,maxSamples:A,samples:I}}function $X(J){let Q=this,$=null,Z=0,W=!1,K=!1,H=new X9,Y=new P0,X={value:null,needsUpdate:!1};this.uniform=X,this.numPlanes=0,this.numIntersection=0,this.init=function(N,G){let D=N.length!==0||G||Z!==0||W;return W=G,Z=N.length,D},this.beginShadows=function(){K=!0,E(null)},this.endShadows=function(){K=!1},this.setGlobalState=function(N,G){$=E(N,G,0)},this.setState=function(N,G,D){let{clippingPlanes:M,clipIntersection:z,clipShadows:F}=N,q=J.get(N);if(!W||M===null||M.length===0||K&&!F)if(K)E(null);else U();else{let _=K?0:Z,w=_*4,V=q.clippingState||null;X.value=V,V=E(M,G,w,D);for(let A=0;A!==w;++A)V[A]=$[A];q.clippingState=V,this.numIntersection=z?this.numPlanes:0,this.numPlanes+=_}};function U(){if(X.value!==$)X.value=$,X.needsUpdate=Z>0;Q.numPlanes=Z,Q.numIntersection=0}function E(N,G,D,M){let z=N!==null?N.length:0,F=null;if(z!==0){if(F=X.value,M!==!0||F===null){let q=D+z*4,_=G.matrixWorldInverse;if(Y.getNormalMatrix(_),F===null||F.length<q)F=new Float32Array(q);for(let w=0,V=D;w!==z;++w,V+=4)H.copy(N[w]).applyMatrix4(_,Y),H.normal.toArray(F,V),F[V+3]=H.constant}X.value=F,X.needsUpdate=!0}return Q.numPlanes=z,Q.numIntersection=0,F}}var P9=4,gZ=[0.125,0.215,0.35,0.446,0.526,0.582],i9=20,ZX=256,b8=new b6,pZ=new g0,mQ=null,dQ=0,lQ=0,uQ=!1,WX=new b;class sQ{constructor(J){this._renderer=J,this._pingPongRenderTarget=null,this._lodMax=0,this._cubeSize=0,this._sizeLods=[],this._sigmas=[],this._lodMeshes=[],this._backgroundBox=null,this._cubemapMaterial=null,this._equirectMaterial=null,this._blurMaterial=null,this._ggxMaterial=null}fromScene(J,Q=0,$=0.1,Z=100,W={}){let{size:K=256,position:H=WX}=W;mQ=this._renderer.getRenderTarget(),dQ=this._renderer.getActiveCubeFace(),lQ=this._renderer.getActiveMipmapLevel(),uQ=this._renderer.xr.enabled,this._renderer.xr.enabled=!1,this._setSize(K);let Y=this._allocateTargets();if(Y.depthBuffer=!0,this._sceneToCubeUV(J,$,Z,Y,H),Q>0)this._blur(Y,0,0,Q);return this._applyPMREM(Y),this._cleanup(Y),Y}fromEquirectangular(J,Q=null){return this._fromTexture(J,Q)}fromCubemap(J,Q=null){return this._fromTexture(J,Q)}compileCubemapShader(){if(this._cubemapMaterial===null)this._cubemapMaterial=lZ(),this._compileMaterial(this._cubemapMaterial)}compileEquirectangularShader(){if(this._equirectMaterial===null)this._equirectMaterial=dZ(),this._compileMaterial(this._equirectMaterial)}dispose(){if(this._dispose(),this._cubemapMaterial!==null)this._cubemapMaterial.dispose();if(this._equirectMaterial!==null)this._equirectMaterial.dispose();if(this._backgroundBox!==null)this._backgroundBox.geometry.dispose(),this._backgroundBox.material.dispose()}_setSize(J){this._lodMax=Math.floor(Math.log2(J)),this._cubeSize=Math.pow(2,this._lodMax)}_dispose(){if(this._blurMaterial!==null)this._blurMaterial.dispose();if(this._ggxMaterial!==null)this._ggxMaterial.dispose();if(this._pingPongRenderTarget!==null)this._pingPongRenderTarget.dispose();for(let J=0;J<this._lodMeshes.length;J++)this._lodMeshes[J].geometry.dispose()}_cleanup(J){this._renderer.setRenderTarget(mQ,dQ,lQ),this._renderer.xr.enabled=uQ,J.scissorTest=!1,k8(J,0,0,J.width,J.height)}_fromTexture(J,Q){if(J.mapping===F8||J.mapping===b9)this._setSize(J.image.length===0?16:J.image[0].width||J.image[0].image.width);else this._setSize(J.image.width/4);mQ=this._renderer.getRenderTarget(),dQ=this._renderer.getActiveCubeFace(),lQ=this._renderer.getActiveMipmapLevel(),uQ=this._renderer.xr.enabled,this._renderer.xr.enabled=!1;let $=Q||this._allocateTargets();return this._textureToCubeUV(J,$),this._applyPMREM($),this._cleanup($),$}_allocateTargets(){let J=3*Math.max(this._cubeSize,112),Q=4*this._cubeSize,$={magFilter:_J,minFilter:_J,generateMipmaps:!1,type:E9,format:eJ,colorSpace:GQ,depthBuffer:!1},Z=mZ(J,Q,$);if(this._pingPongRenderTarget===null||this._pingPongRenderTarget.width!==J||this._pingPongRenderTarget.height!==Q){if(this._pingPongRenderTarget!==null)this._dispose();this._pingPongRenderTarget=mZ(J,Q,$);let{_lodMax:W}=this;({lodMeshes:this._lodMeshes,sizeLods:this._sizeLods,sigmas:this._sigmas}=KX(W)),this._blurMaterial=YX(W,J,Q),this._ggxMaterial=HX(W,J,Q)}return Z}_compileMaterial(J){let Q=new sJ(new jJ,J);this._renderer.compile(Q,b8)}_sceneToCubeUV(J,Q,$,Z,W){let Y=new IJ(90,1,Q,$),X=[1,-1,1,1,1,1],U=[1,1,1,-1,-1,-1],E=this._renderer,N=E.autoClear,G=E.toneMapping;if(E.getClearColor(pZ),E.toneMapping=cJ,E.autoClear=!1,E.state.buffers.depth.getReversed())E.setRenderTarget(Z),E.clearDepth(),E.setRenderTarget(null);if(this._backgroundBox===null)this._backgroundBox=new sJ(new O8,new P6({name:"PMREM.Background",side:CJ,depthWrite:!1,depthTest:!1}));let M=this._backgroundBox,z=M.material,F=!1,q=J.background;if(q){if(q.isColor)z.color.copy(q),J.background=null,F=!0}else z.color.copy(pZ),F=!0;for(let _=0;_<6;_++){let w=_%3;if(w===0)Y.up.set(0,X[_],0),Y.position.set(W.x,W.y,W.z),Y.lookAt(W.x+U[_],W.y,W.z);else if(w===1)Y.up.set(0,0,X[_]),Y.position.set(W.x,W.y,W.z),Y.lookAt(W.x,W.y+U[_],W.z);else Y.up.set(0,X[_],0),Y.position.set(W.x,W.y,W.z),Y.lookAt(W.x,W.y,W.z+U[_]);let V=this._cubeSize;if(k8(Z,w*V,_>2?V:0,V,V),E.setRenderTarget(Z),F)E.render(M,Y);E.render(J,Y)}E.toneMapping=G,E.autoClear=N,J.background=q}_textureToCubeUV(J,Q){let $=this._renderer,Z=J.mapping===F8||J.mapping===b9;if(Z){if(this._cubemapMaterial===null)this._cubemapMaterial=lZ();this._cubemapMaterial.uniforms.flipEnvMap.value=J.isRenderTargetTexture===!1?-1:1}else if(this._equirectMaterial===null)this._equirectMaterial=dZ();let W=Z?this._cubemapMaterial:this._equirectMaterial,K=this._lodMeshes[0];K.material=W;let H=W.uniforms;H.envMap.value=J;let Y=this._cubeSize;k8(Q,0,0,3*Y,2*Y),$.setRenderTarget(Q),$.render(K,b8)}_applyPMREM(J){let Q=this._renderer,$=Q.autoClear;Q.autoClear=!1;let Z=this._lodMeshes.length;for(let W=1;W<Z;W++)this._applyGGXFilter(J,W-1,W);Q.autoClear=$}_applyGGXFilter(J,Q,$){let Z=this._renderer,W=this._pingPongRenderTarget,K=this._ggxMaterial,H=this._lodMeshes[$];H.material=K;let Y=K.uniforms,X=$/(this._lodMeshes.length-1),U=Q/(this._lodMeshes.length-1),E=Math.sqrt(X*X-U*U),N=0+X*1.25,G=E*N,{_lodMax:D}=this,M=this._sizeLods[$],z=3*M*($>D-P9?$-D+P9:0),F=4*(this._cubeSize-M);Y.envMap.value=J.texture,Y.roughness.value=G,Y.mipInt.value=D-Q,k8(W,z,F,3*M,2*M),Z.setRenderTarget(W),Z.render(H,b8),Y.envMap.value=W.texture,Y.roughness.value=0,Y.mipInt.value=D-$,k8(J,z,F,3*M,2*M),Z.setRenderTarget(J),Z.render(H,b8)}_blur(J,Q,$,Z,W){let K=this._pingPongRenderTarget;this._halfBlur(J,K,Q,$,Z,"latitudinal",W),this._halfBlur(K,J,$,$,Z,"longitudinal",W)}_halfBlur(J,Q,$,Z,W,K,H){let Y=this._renderer,X=this._blurMaterial;if(K!=="latitudinal"&&K!=="longitudinal")_0("blur direction must be either latitudinal or longitudinal!");let U=3,E=this._lodMeshes[Z];E.material=X;let N=X.uniforms,G=this._sizeLods[$]-1,D=isFinite(W)?Math.PI/(2*G):2*Math.PI/(2*i9-1),M=W/D,z=isFinite(W)?1+Math.floor(U*M):i9;if(z>i9)C0(`sigmaRadians, ${W}, is too large and will clip, as it requested ${z} samples when the maximum is set to ${i9}`);let F=[],q=0;for(let I=0;I<i9;++I){let P=I/M,O=Math.exp(-P*P/2);if(F.push(O),I===0)q+=O;else if(I<z)q+=2*O}for(let I=0;I<F.length;I++)F[I]=F[I]/q;if(N.envMap.value=J.texture,N.samples.value=z,N.weights.value=F,N.latitudinal.value=K==="latitudinal",H)N.poleAxis.value=H;let{_lodMax:_}=this;N.dTheta.value=D,N.mipInt.value=_-$;let w=this._sizeLods[Z],V=3*w*(Z>_-P9?Z-_+P9:0),A=4*(this._cubeSize-w);k8(Q,V,A,3*w,2*w),Y.setRenderTarget(Q),Y.render(E,b8)}}function KX(J){let Q=[],$=[],Z=[],W=J,K=J-P9+1+gZ.length;for(let H=0;H<K;H++){let Y=Math.pow(2,W);Q.push(Y);let X=1/Y;if(H>J-P9)X=gZ[H-J+P9-1];else if(H===0)X=0;$.push(X);let U=1/(Y-2),E=-U,N=1+U,G=[E,E,N,E,N,N,E,E,N,N,E,N],D=6,M=6,z=3,F=2,q=1,_=new Float32Array(z*M*D),w=new Float32Array(F*M*D),V=new Float32Array(q*M*D);for(let I=0;I<D;I++){let P=I%3*2/3-1,O=I>2?0:-1,B=[P,O,0,P+0.6666666666666666,O,0,P+0.6666666666666666,O+1,0,P,O,0,P+0.6666666666666666,O+1,0,P,O+1,0];_.set(B,z*M*I),w.set(G,F*M*I);let l=[I,I,I,I,I,I];V.set(l,q*M*I)}let A=new jJ;if(A.setAttribute("position",new wJ(_,z)),A.setAttribute("uv",new wJ(w,F)),A.setAttribute("faceIndex",new wJ(V,q)),Z.push(new sJ(A,null)),W>P9)W--}return{lodMeshes:Z,sizeLods:Q,sigmas:$}}function mZ(J,Q,$){let Z=new xJ(J,Q,$);return Z.texture.mapping=_8,Z.texture.name="PMREM.cubeUv",Z.scissorTest=!0,Z}function k8(J,Q,$,Z,W){J.viewport.set(Q,$,Z,W),J.scissor.set(Q,$,Z,W)}function HX(J,Q,$){return new gJ({name:"PMREMGGXConvolution",defines:{GGX_SAMPLES:ZX,CUBEUV_TEXEL_WIDTH:1/Q,CUBEUV_TEXEL_HEIGHT:1/$,CUBEUV_MAX_MIP:`${J}.0`},uniforms:{envMap:{value:null},roughness:{value:0},mipInt:{value:0}},vertexShader:p6(),fragmentShader:`

			precision highp float;
			precision highp int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;
			uniform float roughness;
			uniform float mipInt;

			#define ENVMAP_TYPE_CUBE_UV
			#include <cube_uv_reflection_fragment>

			#define PI 3.14159265359

			// Van der Corput radical inverse
			float radicalInverse_VdC(uint bits) {
				bits = (bits << 16u) | (bits >> 16u);
				bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
				bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
				bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
				bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
				return float(bits) * 2.3283064365386963e-10; // / 0x100000000
			}

			// Hammersley sequence
			vec2 hammersley(uint i, uint N) {
				return vec2(float(i) / float(N), radicalInverse_VdC(i));
			}

			// GGX VNDF importance sampling (Eric Heitz 2018)
			// "Sampling the GGX Distribution of Visible Normals"
			// https://jcgt.org/published/0007/04/01/
			vec3 importanceSampleGGX_VNDF(vec2 Xi, vec3 V, float roughness) {
				float alpha = roughness * roughness;

				// Section 4.1: Orthonormal basis
				vec3 T1 = vec3(1.0, 0.0, 0.0);
				vec3 T2 = cross(V, T1);

				// Section 4.2: Parameterization of projected area
				float r = sqrt(Xi.x);
				float phi = 2.0 * PI * Xi.y;
				float t1 = r * cos(phi);
				float t2 = r * sin(phi);
				float s = 0.5 * (1.0 + V.z);
				t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;

				// Section 4.3: Reprojection onto hemisphere
				vec3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * V;

				// Section 3.4: Transform back to ellipsoid configuration
				return normalize(vec3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
			}

			void main() {
				vec3 N = normalize(vOutputDirection);
				vec3 V = N; // Assume view direction equals normal for pre-filtering

				vec3 prefilteredColor = vec3(0.0);
				float totalWeight = 0.0;

				// For very low roughness, just sample the environment directly
				if (roughness < 0.001) {
					gl_FragColor = vec4(bilinearCubeUV(envMap, N, mipInt), 1.0);
					return;
				}

				// Tangent space basis for VNDF sampling
				vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
				vec3 tangent = normalize(cross(up, N));
				vec3 bitangent = cross(N, tangent);

				for(uint i = 0u; i < uint(GGX_SAMPLES); i++) {
					vec2 Xi = hammersley(i, uint(GGX_SAMPLES));

					// For PMREM, V = N, so in tangent space V is always (0, 0, 1)
					vec3 H_tangent = importanceSampleGGX_VNDF(Xi, vec3(0.0, 0.0, 1.0), roughness);

					// Transform H back to world space
					vec3 H = normalize(tangent * H_tangent.x + bitangent * H_tangent.y + N * H_tangent.z);
					vec3 L = normalize(2.0 * dot(V, H) * H - V);

					float NdotL = max(dot(N, L), 0.0);

					if(NdotL > 0.0) {
						// Sample environment at fixed mip level
						// VNDF importance sampling handles the distribution filtering
						vec3 sampleColor = bilinearCubeUV(envMap, L, mipInt);

						// Weight by NdotL for the split-sum approximation
						// VNDF PDF naturally accounts for the visible microfacet distribution
						prefilteredColor += sampleColor * NdotL;
						totalWeight += NdotL;
					}
				}

				if (totalWeight > 0.0) {
					prefilteredColor = prefilteredColor / totalWeight;
				}

				gl_FragColor = vec4(prefilteredColor, 1.0);
			}
		`,blending:tJ,depthTest:!1,depthWrite:!1})}function YX(J,Q,$){let Z=new Float32Array(i9),W=new b(0,1,0);return new gJ({name:"SphericalGaussianBlur",defines:{n:i9,CUBEUV_TEXEL_WIDTH:1/Q,CUBEUV_TEXEL_HEIGHT:1/$,CUBEUV_MAX_MIP:`${J}.0`},uniforms:{envMap:{value:null},samples:{value:1},weights:{value:Z},latitudinal:{value:!1},dTheta:{value:0},mipInt:{value:0},poleAxis:{value:W}},vertexShader:p6(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;
			uniform int samples;
			uniform float weights[ n ];
			uniform bool latitudinal;
			uniform float dTheta;
			uniform float mipInt;
			uniform vec3 poleAxis;

			#define ENVMAP_TYPE_CUBE_UV
			#include <cube_uv_reflection_fragment>

			vec3 getSample( float theta, vec3 axis ) {

				float cosTheta = cos( theta );
				// Rodrigues' axis-angle rotation
				vec3 sampleDirection = vOutputDirection * cosTheta
					+ cross( axis, vOutputDirection ) * sin( theta )
					+ axis * dot( axis, vOutputDirection ) * ( 1.0 - cosTheta );

				return bilinearCubeUV( envMap, sampleDirection, mipInt );

			}

			void main() {

				vec3 axis = latitudinal ? poleAxis : cross( poleAxis, vOutputDirection );

				if ( all( equal( axis, vec3( 0.0 ) ) ) ) {

					axis = vec3( vOutputDirection.z, 0.0, - vOutputDirection.x );

				}

				axis = normalize( axis );

				gl_FragColor = vec4( 0.0, 0.0, 0.0, 1.0 );
				gl_FragColor.rgb += weights[ 0 ] * getSample( 0.0, axis );

				for ( int i = 1; i < n; i++ ) {

					if ( i >= samples ) {

						break;

					}

					float theta = dTheta * float( i );
					gl_FragColor.rgb += weights[ i ] * getSample( -1.0 * theta, axis );
					gl_FragColor.rgb += weights[ i ] * getSample( theta, axis );

				}

			}
		`,blending:tJ,depthTest:!1,depthWrite:!1})}function dZ(){return new gJ({name:"EquirectangularToCubeUV",uniforms:{envMap:{value:null}},vertexShader:p6(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;

			#include <common>

			void main() {

				vec3 outputDirection = normalize( vOutputDirection );
				vec2 uv = equirectUv( outputDirection );

				gl_FragColor = vec4( texture2D ( envMap, uv ).rgb, 1.0 );

			}
		`,blending:tJ,depthTest:!1,depthWrite:!1})}function lZ(){return new gJ({name:"CubemapToCubeUV",uniforms:{envMap:{value:null},flipEnvMap:{value:-1}},vertexShader:p6(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			uniform float flipEnvMap;

			varying vec3 vOutputDirection;

			uniform samplerCube envMap;

			void main() {

				gl_FragColor = textureCube( envMap, vec3( flipEnvMap * vOutputDirection.x, vOutputDirection.yz ) );

			}
		`,blending:tJ,depthTest:!1,depthWrite:!1})}function p6(){return`

		precision mediump float;
		precision mediump int;

		attribute float faceIndex;

		varying vec3 vOutputDirection;

		// RH coordinate system; PMREM face-indexing convention
		vec3 getDirection( vec2 uv, float face ) {

			uv = 2.0 * uv - 1.0;

			vec3 direction = vec3( uv, 1.0 );

			if ( face == 0.0 ) {

				direction = direction.zyx; // ( 1, v, u ) pos x

			} else if ( face == 1.0 ) {

				direction = direction.xzy;
				direction.xz *= -1.0; // ( -u, 1, -v ) pos y

			} else if ( face == 2.0 ) {

				direction.x *= -1.0; // ( -u, v, 1 ) pos z

			} else if ( face == 3.0 ) {

				direction = direction.zyx;
				direction.xz *= -1.0; // ( -1, v, -u ) neg x

			} else if ( face == 4.0 ) {

				direction = direction.xzy;
				direction.xy *= -1.0; // ( -u, -1, v ) neg y

			} else if ( face == 5.0 ) {

				direction.z *= -1.0; // ( u, v, -1 ) neg z

			}

			return direction;

		}

		void main() {

			vOutputDirection = getDirection( uv, faceIndex );
			gl_Position = vec4( position, 1.0 );

		}
	`}class aQ extends xJ{constructor(J=1,Q={}){super(J,J,Q);this.isWebGLCubeRenderTarget=!0;let $={width:J,height:J,depth:1},Z=[$,$,$,$,$,$];this.texture=new j6(Z),this._setTextureOptions(Q),this.texture.isRenderTargetTexture=!0}fromEquirectangularTexture(J,Q){this.texture.type=Q.type,this.texture.colorSpace=Q.colorSpace,this.texture.generateMipmaps=Q.generateMipmaps,this.texture.minFilter=Q.minFilter,this.texture.magFilter=Q.magFilter;let $={uniforms:{tEquirect:{value:null}},vertexShader:`

				varying vec3 vWorldDirection;

				vec3 transformDirection( in vec3 dir, in mat4 matrix ) {

					return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );

				}

				void main() {

					vWorldDirection = transformDirection( position, modelMatrix );

					#include <begin_vertex>
					#include <project_vertex>

				}
			`,fragmentShader:`

				uniform sampler2D tEquirect;

				varying vec3 vWorldDirection;

				#include <common>

				void main() {

					vec3 direction = normalize( vWorldDirection );

					vec2 sampleUV = equirectUv( direction );

					gl_FragColor = texture2D( tEquirect, sampleUV );

				}
			`},Z=new O8(5,5,5),W=new gJ({name:"CubemapFromEquirect",uniforms:u9($.uniforms),vertexShader:$.vertexShader,fragmentShader:$.fragmentShader,side:CJ,blending:tJ});W.uniforms.tEquirect.value=Q;let K=new sJ(Z,W),H=Q.minFilter;if(Q.minFilter===h9)Q.minFilter=_J;return new vQ(1,10,this).update(J,K),Q.minFilter=H,K.geometry.dispose(),K.material.dispose(),this}clear(J,Q=!0,$=!0,Z=!0){let W=J.getRenderTarget();for(let K=0;K<6;K++)J.setRenderTarget(this,K),J.clear(Q,$,Z);J.setRenderTarget(W)}}function XX(J){let Q=new WeakMap,$=new WeakMap,Z=null;function W(G,D=!1){if(G===null||G===void 0)return null;if(D)return H(G);return K(G)}function K(G){if(G&&G.isTexture){let D=G.mapping;if(D===E6||D===N6)if(Q.has(G)){let M=Q.get(G).texture;return Y(M,G.mapping)}else{let M=G.image;if(M&&M.height>0){let z=new aQ(M.height);return z.fromEquirectangularTexture(J,G),Q.set(G,z),G.addEventListener("dispose",U),Y(z.texture,G.mapping)}else return null}}return G}function H(G){if(G&&G.isTexture){let D=G.mapping,M=D===E6||D===N6,z=D===F8||D===b9;if(M||z){let F=$.get(G),q=F!==void 0?F.texture.pmremVersion:0;if(G.isRenderTargetTexture&&G.pmremVersion!==q){if(Z===null)Z=new sQ(J);return F=M?Z.fromEquirectangular(G,F):Z.fromCubemap(G,F),F.texture.pmremVersion=G.pmremVersion,$.set(G,F),F.texture}else if(F!==void 0)return F.texture;else{let _=G.image;if(M&&_&&_.height>0||z&&_&&X(_)){if(Z===null)Z=new sQ(J);return F=M?Z.fromEquirectangular(G):Z.fromCubemap(G),F.texture.pmremVersion=G.pmremVersion,$.set(G,F),G.addEventListener("dispose",E),F.texture}else return null}}}return G}function Y(G,D){if(D===E6)G.mapping=F8;else if(D===N6)G.mapping=b9;return G}function X(G){let D=0,M=6;for(let z=0;z<M;z++)if(G[z]!==void 0)D++;return D===M}function U(G){let D=G.target;D.removeEventListener("dispose",U);let M=Q.get(D);if(M!==void 0)Q.delete(D),M.dispose()}function E(G){let D=G.target;D.removeEventListener("dispose",E);let M=$.get(D);if(M!==void 0)$.delete(D),M.dispose()}function N(){if(Q=new WeakMap,$=new WeakMap,Z!==null)Z.dispose(),Z=null}return{get:W,dispose:N}}function UX(J){let Q={};function $(Z){if(Q[Z]!==void 0)return Q[Z];let W=J.getExtension(Z);return Q[Z]=W,W}return{has:function(Z){return $(Z)!==null},init:function(){$("EXT_color_buffer_float"),$("WEBGL_clip_cull_distance"),$("OES_texture_float_linear"),$("EXT_color_buffer_half_float"),$("WEBGL_multisampled_render_to_texture"),$("WEBGL_render_shared_exponent")},get:function(Z){let W=$(Z);if(W===null)v9("WebGLRenderer: "+Z+" extension not supported.");return W}}}function GX(J,Q,$,Z){let W={},K=new WeakMap;function H(N){let G=N.target;if(G.index!==null)Q.remove(G.index);for(let M in G.attributes)Q.remove(G.attributes[M]);G.removeEventListener("dispose",H),delete W[G.id];let D=K.get(G);if(D)Q.remove(D),K.delete(G);if(Z.releaseStatesOfGeometry(G),G.isInstancedBufferGeometry===!0)delete G._maxInstanceCount;$.memory.geometries--}function Y(N,G){if(W[G.id]===!0)return G;return G.addEventListener("dispose",H),W[G.id]=!0,$.memory.geometries++,G}function X(N){let G=N.attributes;for(let D in G)Q.update(G[D],J.ARRAY_BUFFER)}function U(N){let G=[],D=N.index,M=N.attributes.position,z=0;if(M===void 0)return;if(D!==null){let _=D.array;z=D.version;for(let w=0,V=_.length;w<V;w+=3){let A=_[w+0],I=_[w+1],P=_[w+2];G.push(A,I,I,P,P,A)}}else{let _=M.array;z=M.version;for(let w=0,V=_.length/3-1;w<V;w+=3){let A=w+0,I=w+1,P=w+2;G.push(A,I,I,P,P,A)}}let F=new(M.count>=65535?C6:w6)(G,1);F.version=z;let q=K.get(N);if(q)Q.remove(q);K.set(N,F)}function E(N){let G=K.get(N);if(G){let D=N.index;if(D!==null){if(G.version<D.version)U(N)}}else U(N);return K.get(N)}return{get:Y,update:X,getWireframeAttribute:E}}function EX(J,Q,$){let Z;function W(N){Z=N}let K,H;function Y(N){K=N.type,H=N.bytesPerElement}function X(N,G){J.drawElements(Z,G,K,N*H),$.update(G,Z,1)}function U(N,G,D){if(D===0)return;J.drawElementsInstanced(Z,G,K,N*H,D),$.update(G,Z,D)}function E(N,G,D){if(D===0)return;Q.get("WEBGL_multi_draw").multiDrawElementsWEBGL(Z,G,0,K,N,0,D);let z=0;for(let F=0;F<D;F++)z+=G[F];$.update(z,Z,1)}this.setMode=W,this.setIndex=Y,this.render=X,this.renderInstances=U,this.renderMultiDraw=E}function NX(J){let Q={geometries:0,textures:0},$={frame:0,calls:0,triangles:0,points:0,lines:0};function Z(K,H,Y){switch($.calls++,H){case J.TRIANGLES:$.triangles+=Y*(K/3);break;case J.LINES:$.lines+=Y*(K/2);break;case J.LINE_STRIP:$.lines+=Y*(K-1);break;case J.LINE_LOOP:$.lines+=Y*K;break;case J.POINTS:$.points+=Y*K;break;default:_0("WebGLInfo: Unknown draw mode:",H);break}}function W(){$.calls=0,$.triangles=0,$.points=0,$.lines=0}return{memory:Q,render:$,programs:null,autoReset:!0,reset:W,update:Z}}function qX(J,Q,$){let Z=new WeakMap,W=new KJ;function K(H,Y,X){let U=H.morphTargetInfluences,E=Y.morphAttributes.position||Y.morphAttributes.normal||Y.morphAttributes.color,N=E!==void 0?E.length:0,G=Z.get(Y);if(G===void 0||G.count!==N){let B=function(){P.dispose(),Z.delete(Y),Y.removeEventListener("dispose",B)};if(G!==void 0)G.texture.dispose();let D=Y.morphAttributes.position!==void 0,M=Y.morphAttributes.normal!==void 0,z=Y.morphAttributes.color!==void 0,F=Y.morphAttributes.position||[],q=Y.morphAttributes.normal||[],_=Y.morphAttributes.color||[],w=0;if(D===!0)w=1;if(M===!0)w=2;if(z===!0)w=3;let V=Y.attributes.position.count*w,A=1;if(V>Q.maxTextureSize)A=Math.ceil(V/Q.maxTextureSize),V=Q.maxTextureSize;let I=new Float32Array(V*A*4*N),P=new z6(I,V,A,N);P.type=G9,P.needsUpdate=!0;let O=w*4;for(let l=0;l<N;l++){let C=F[l],m=q[l],o=_[l],p=V*A*4*l;for(let n=0;n<C.count;n++){let u=n*O;if(D===!0)W.fromBufferAttribute(C,n),I[p+u+0]=W.x,I[p+u+1]=W.y,I[p+u+2]=W.z,I[p+u+3]=0;if(M===!0)W.fromBufferAttribute(m,n),I[p+u+4]=W.x,I[p+u+5]=W.y,I[p+u+6]=W.z,I[p+u+7]=0;if(z===!0)W.fromBufferAttribute(o,n),I[p+u+8]=W.x,I[p+u+9]=W.y,I[p+u+10]=W.z,I[p+u+11]=o.itemSize===4?W.w:1}}G={count:N,texture:P,size:new u0(V,A)},Z.set(Y,G),Y.addEventListener("dispose",B)}if(H.isInstancedMesh===!0&&H.morphTexture!==null)X.getUniforms().setValue(J,"morphTexture",H.morphTexture,$);else{let D=0;for(let z=0;z<U.length;z++)D+=U[z];let M=Y.morphTargetsRelative?1:1-D;X.getUniforms().setValue(J,"morphTargetBaseInfluence",M),X.getUniforms().setValue(J,"morphTargetInfluences",U)}X.getUniforms().setValue(J,"morphTargetsTexture",G.texture,$),X.getUniforms().setValue(J,"morphTargetsTextureSize",G.size)}return{update:K}}function FX(J,Q,$,Z,W){let K=new WeakMap;function H(U){let E=W.render.frame,N=U.geometry,G=Q.get(U,N);if(K.get(G)!==E)Q.update(G),K.set(G,E);if(U.isInstancedMesh){if(U.hasEventListener("dispose",X)===!1)U.addEventListener("dispose",X);if(K.get(U)!==E){if($.update(U.instanceMatrix,J.ARRAY_BUFFER),U.instanceColor!==null)$.update(U.instanceColor,J.ARRAY_BUFFER);K.set(U,E)}}if(U.isSkinnedMesh){let D=U.skeleton;if(K.get(D)!==E)D.update(),K.set(D,E)}return G}function Y(){K=new WeakMap}function X(U){let E=U.target;if(E.removeEventListener("dispose",X),Z.releaseStatesOfObject(E),$.remove(E.instanceMatrix),E.instanceColor!==null)$.remove(E.instanceColor)}return{update:H,dispose:Y}}var DX={[L7]:"LINEAR_TONE_MAPPING",[V7]:"REINHARD_TONE_MAPPING",[B7]:"CINEON_TONE_MAPPING",[z7]:"ACES_FILMIC_TONE_MAPPING",[A7]:"AGX_TONE_MAPPING",[w7]:"NEUTRAL_TONE_MAPPING",[I7]:"CUSTOM_TONE_MAPPING"};function RX(J,Q,$,Z,W,K){let H=new xJ(Q,$,{type:J,depthBuffer:W,stencilBuffer:K,samples:Z?4:0,depthTexture:W?new _9(Q,$):void 0}),Y=new xJ(Q,$,{type:E9,depthBuffer:!1,stencilBuffer:!1}),X=new jJ;X.setAttribute("position",new uJ([-1,3,0,-1,-1,0,3,-1,0],3)),X.setAttribute("uv",new uJ([0,2,0,0,2,0],2));let U=new VQ({uniforms:{tDiffuse:{value:null}},vertexShader:`
			precision highp float;

			uniform mat4 modelViewMatrix;
			uniform mat4 projectionMatrix;

			attribute vec3 position;
			attribute vec2 uv;

			varying vec2 vUv;

			void main() {
				vUv = uv;
				gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );
			}`,fragmentShader:`
			precision highp float;

			uniform sampler2D tDiffuse;

			varying vec2 vUv;

			#include <tonemapping_pars_fragment>
			#include <colorspace_pars_fragment>

			void main() {
				gl_FragColor = texture2D( tDiffuse, vUv );

				#ifdef LINEAR_TONE_MAPPING
					gl_FragColor.rgb = LinearToneMapping( gl_FragColor.rgb );
				#elif defined( REINHARD_TONE_MAPPING )
					gl_FragColor.rgb = ReinhardToneMapping( gl_FragColor.rgb );
				#elif defined( CINEON_TONE_MAPPING )
					gl_FragColor.rgb = CineonToneMapping( gl_FragColor.rgb );
				#elif defined( ACES_FILMIC_TONE_MAPPING )
					gl_FragColor.rgb = ACESFilmicToneMapping( gl_FragColor.rgb );
				#elif defined( AGX_TONE_MAPPING )
					gl_FragColor.rgb = AgXToneMapping( gl_FragColor.rgb );
				#elif defined( NEUTRAL_TONE_MAPPING )
					gl_FragColor.rgb = NeutralToneMapping( gl_FragColor.rgb );
				#elif defined( CUSTOM_TONE_MAPPING )
					gl_FragColor.rgb = CustomToneMapping( gl_FragColor.rgb );
				#endif

				#ifdef SRGB_TRANSFER
					gl_FragColor = sRGBTransferOETF( gl_FragColor );
				#endif
			}`,depthTest:!1,depthWrite:!1}),E=new sJ(X,U),N=new b6(-1,1,1,-1,0,1),G=null,D=null,M=!1,z,F=null,q=[],_=!1;this.setSize=function(w,V){H.setSize(w,V),Y.setSize(w,V);for(let A=0;A<q.length;A++){let I=q[A];if(I.setSize)I.setSize(w,V)}},this.setEffects=function(w){q=w,_=q.length>0&&q[0].isRenderPass===!0;let{width:V,height:A}=H;for(let I=0;I<q.length;I++){let P=q[I];if(P.setSize)P.setSize(V,A)}},this.begin=function(w,V){if(M)return!1;if(w.toneMapping===cJ&&q.length===0)return!1;if(F=V,V!==null){let{width:A,height:I}=V;if(H.width!==A||H.height!==I)this.setSize(A,I)}if(_===!1)w.setRenderTarget(H);return z=w.toneMapping,w.toneMapping=cJ,!0},this.hasRenderPass=function(){return _},this.end=function(w,V){w.toneMapping=z,M=!0;let A=H,I=Y;for(let P=0;P<q.length;P++){let O=q[P];if(O.enabled===!1)continue;if(O.render(w,I,A,V),O.needsSwap!==!1){let B=A;A=I,I=B}}if(G!==w.outputColorSpace||D!==w.toneMapping){if(G=w.outputColorSpace,D=w.toneMapping,U.defines={},h0.getTransfer(G)===r0)U.defines.SRGB_TRANSFER="";let P=DX[D];if(P)U.defines[P]="";U.needsUpdate=!0}U.uniforms.tDiffuse.value=A.texture,w.setRenderTarget(F),w.render(E,N),F=null,M=!1},this.isCompositing=function(){return M},this.dispose=function(){if(H.depthTexture)H.depthTexture.dispose();H.dispose(),Y.dispose(),X.dispose(),U.dispose()}}var UW=new VJ,iQ=new _9(1,1),GW=new z6,EW=new OQ,NW=new j6,uZ=[],cZ=[],nZ=new Float32Array(16),sZ=new Float32Array(9),iZ=new Float32Array(4);function M8(J,Q,$){let Z=J[0];if(Z<=0||Z>0)return J;let W=Q*$,K=uZ[W];if(K===void 0)K=new Float32Array(W),uZ[W]=K;if(Q!==0){Z.toArray(K,0);for(let H=1,Y=0;H!==Q;++H)Y+=$,J[H].toArray(K,Y)}return K}function NJ(J,Q){if(J.length!==Q.length)return!1;for(let $=0,Z=J.length;$<Z;$++)if(J[$]!==Q[$])return!1;return!0}function qJ(J,Q){for(let $=0,Z=Q.length;$<Z;$++)J[$]=Q[$]}function m6(J,Q){let $=cZ[Q];if($===void 0)$=new Int32Array(Q),cZ[Q]=$;for(let Z=0;Z!==Q;++Z)$[Z]=J.allocateTextureUnit();return $}function OX(J,Q){let $=this.cache;if($[0]===Q)return;J.uniform1f(this.addr,Q),$[0]=Q}function kX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y)J.uniform2f(this.addr,Q.x,Q.y),$[0]=Q.x,$[1]=Q.y}else{if(NJ($,Q))return;J.uniform2fv(this.addr,Q),qJ($,Q)}}function MX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y||$[2]!==Q.z)J.uniform3f(this.addr,Q.x,Q.y,Q.z),$[0]=Q.x,$[1]=Q.y,$[2]=Q.z}else if(Q.r!==void 0){if($[0]!==Q.r||$[1]!==Q.g||$[2]!==Q.b)J.uniform3f(this.addr,Q.r,Q.g,Q.b),$[0]=Q.r,$[1]=Q.g,$[2]=Q.b}else{if(NJ($,Q))return;J.uniform3fv(this.addr,Q),qJ($,Q)}}function LX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y||$[2]!==Q.z||$[3]!==Q.w)J.uniform4f(this.addr,Q.x,Q.y,Q.z,Q.w),$[0]=Q.x,$[1]=Q.y,$[2]=Q.z,$[3]=Q.w}else{if(NJ($,Q))return;J.uniform4fv(this.addr,Q),qJ($,Q)}}function VX(J,Q){let $=this.cache,Z=Q.elements;if(Z===void 0){if(NJ($,Q))return;J.uniformMatrix2fv(this.addr,!1,Q),qJ($,Q)}else{if(NJ($,Z))return;iZ.set(Z),J.uniformMatrix2fv(this.addr,!1,iZ),qJ($,Z)}}function BX(J,Q){let $=this.cache,Z=Q.elements;if(Z===void 0){if(NJ($,Q))return;J.uniformMatrix3fv(this.addr,!1,Q),qJ($,Q)}else{if(NJ($,Z))return;sZ.set(Z),J.uniformMatrix3fv(this.addr,!1,sZ),qJ($,Z)}}function zX(J,Q){let $=this.cache,Z=Q.elements;if(Z===void 0){if(NJ($,Q))return;J.uniformMatrix4fv(this.addr,!1,Q),qJ($,Q)}else{if(NJ($,Z))return;nZ.set(Z),J.uniformMatrix4fv(this.addr,!1,nZ),qJ($,Z)}}function IX(J,Q){let $=this.cache;if($[0]===Q)return;J.uniform1i(this.addr,Q),$[0]=Q}function AX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y)J.uniform2i(this.addr,Q.x,Q.y),$[0]=Q.x,$[1]=Q.y}else{if(NJ($,Q))return;J.uniform2iv(this.addr,Q),qJ($,Q)}}function wX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y||$[2]!==Q.z)J.uniform3i(this.addr,Q.x,Q.y,Q.z),$[0]=Q.x,$[1]=Q.y,$[2]=Q.z}else{if(NJ($,Q))return;J.uniform3iv(this.addr,Q),qJ($,Q)}}function CX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y||$[2]!==Q.z||$[3]!==Q.w)J.uniform4i(this.addr,Q.x,Q.y,Q.z,Q.w),$[0]=Q.x,$[1]=Q.y,$[2]=Q.z,$[3]=Q.w}else{if(NJ($,Q))return;J.uniform4iv(this.addr,Q),qJ($,Q)}}function _X(J,Q){let $=this.cache;if($[0]===Q)return;J.uniform1ui(this.addr,Q),$[0]=Q}function PX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y)J.uniform2ui(this.addr,Q.x,Q.y),$[0]=Q.x,$[1]=Q.y}else{if(NJ($,Q))return;J.uniform2uiv(this.addr,Q),qJ($,Q)}}function TX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y||$[2]!==Q.z)J.uniform3ui(this.addr,Q.x,Q.y,Q.z),$[0]=Q.x,$[1]=Q.y,$[2]=Q.z}else{if(NJ($,Q))return;J.uniform3uiv(this.addr,Q),qJ($,Q)}}function SX(J,Q){let $=this.cache;if(Q.x!==void 0){if($[0]!==Q.x||$[1]!==Q.y||$[2]!==Q.z||$[3]!==Q.w)J.uniform4ui(this.addr,Q.x,Q.y,Q.z,Q.w),$[0]=Q.x,$[1]=Q.y,$[2]=Q.z,$[3]=Q.w}else{if(NJ($,Q))return;J.uniform4uiv(this.addr,Q),qJ($,Q)}}function jX(J,Q,$){let Z=this.cache,W=$.allocateTextureUnit();if(Z[0]!==W)J.uniform1i(this.addr,W),Z[0]=W;let K;if(this.type===J.SAMPLER_2D_SHADOW)iQ.compareFunction=$.isReversedDepthBuffer()?B6:V6,K=iQ;else K=UW;$.setTexture2D(Q||K,W)}function yX(J,Q,$){let Z=this.cache,W=$.allocateTextureUnit();if(Z[0]!==W)J.uniform1i(this.addr,W),Z[0]=W;$.setTexture3D(Q||EW,W)}function fX(J,Q,$){let Z=this.cache,W=$.allocateTextureUnit();if(Z[0]!==W)J.uniform1i(this.addr,W),Z[0]=W;$.setTextureCube(Q||NW,W)}function vX(J,Q,$){let Z=this.cache,W=$.allocateTextureUnit();if(Z[0]!==W)J.uniform1i(this.addr,W),Z[0]=W;$.setTexture2DArray(Q||GW,W)}function bX(J){switch(J){case 5126:return OX;case 35664:return kX;case 35665:return MX;case 35666:return LX;case 35674:return VX;case 35675:return BX;case 35676:return zX;case 5124:case 35670:return IX;case 35667:case 35671:return AX;case 35668:case 35672:return wX;case 35669:case 35673:return CX;case 5125:return _X;case 36294:return PX;case 36295:return TX;case 36296:return SX;case 35678:case 36198:case 36298:case 36306:case 35682:return jX;case 35679:case 36299:case 36307:return yX;case 35680:case 36300:case 36308:case 36293:return fX;case 36289:case 36303:case 36311:case 36292:return vX}}function hX(J,Q){J.uniform1fv(this.addr,Q)}function xX(J,Q){let $=M8(Q,this.size,2);J.uniform2fv(this.addr,$)}function gX(J,Q){let $=M8(Q,this.size,3);J.uniform3fv(this.addr,$)}function pX(J,Q){let $=M8(Q,this.size,4);J.uniform4fv(this.addr,$)}function mX(J,Q){let $=M8(Q,this.size,4);J.uniformMatrix2fv(this.addr,!1,$)}function dX(J,Q){let $=M8(Q,this.size,9);J.uniformMatrix3fv(this.addr,!1,$)}function lX(J,Q){let $=M8(Q,this.size,16);J.uniformMatrix4fv(this.addr,!1,$)}function uX(J,Q){J.uniform1iv(this.addr,Q)}function cX(J,Q){J.uniform2iv(this.addr,Q)}function nX(J,Q){J.uniform3iv(this.addr,Q)}function sX(J,Q){J.uniform4iv(this.addr,Q)}function iX(J,Q){J.uniform1uiv(this.addr,Q)}function oX(J,Q){J.uniform2uiv(this.addr,Q)}function aX(J,Q){J.uniform3uiv(this.addr,Q)}function rX(J,Q){J.uniform4uiv(this.addr,Q)}function tX(J,Q,$){let Z=this.cache,W=Q.length,K=m6($,W);if(!NJ(Z,K))J.uniform1iv(this.addr,K),qJ(Z,K);let H;if(this.type===J.SAMPLER_2D_SHADOW)H=iQ;else H=UW;for(let Y=0;Y!==W;++Y)$.setTexture2D(Q[Y]||H,K[Y])}function eX(J,Q,$){let Z=this.cache,W=Q.length,K=m6($,W);if(!NJ(Z,K))J.uniform1iv(this.addr,K),qJ(Z,K);for(let H=0;H!==W;++H)$.setTexture3D(Q[H]||EW,K[H])}function JU(J,Q,$){let Z=this.cache,W=Q.length,K=m6($,W);if(!NJ(Z,K))J.uniform1iv(this.addr,K),qJ(Z,K);for(let H=0;H!==W;++H)$.setTextureCube(Q[H]||NW,K[H])}function QU(J,Q,$){let Z=this.cache,W=Q.length,K=m6($,W);if(!NJ(Z,K))J.uniform1iv(this.addr,K),qJ(Z,K);for(let H=0;H!==W;++H)$.setTexture2DArray(Q[H]||GW,K[H])}function $U(J){switch(J){case 5126:return hX;case 35664:return xX;case 35665:return gX;case 35666:return pX;case 35674:return mX;case 35675:return dX;case 35676:return lX;case 5124:case 35670:return uX;case 35667:case 35671:return cX;case 35668:case 35672:return nX;case 35669:case 35673:return sX;case 5125:return iX;case 36294:return oX;case 36295:return aX;case 36296:return rX;case 35678:case 36198:case 36298:case 36306:case 35682:return tX;case 35679:case 36299:case 36307:return eX;case 35680:case 36300:case 36308:case 36293:return JU;case 36289:case 36303:case 36311:case 36292:return QU}}class qW{constructor(J,Q,$){this.id=J,this.addr=$,this.cache=[],this.type=Q.type,this.setValue=bX(Q.type)}}class FW{constructor(J,Q,$){this.id=J,this.addr=$,this.cache=[],this.type=Q.type,this.size=Q.size,this.setValue=$U(Q.type)}}class DW{constructor(J){this.id=J,this.seq=[],this.map={}}setValue(J,Q,$){let Z=this.seq;for(let W=0,K=Z.length;W!==K;++W){let H=Z[W];H.setValue(J,Q[H.id],$)}}}var cQ=/(\w+)(\])?(\[|\.)?/g;function oZ(J,Q){J.seq.push(Q),J.map[Q.id]=Q}function ZU(J,Q,$){let Z=J.name,W=Z.length;cQ.lastIndex=0;while(!0){let K=cQ.exec(Z),H=cQ.lastIndex,Y=K[1],X=K[2]==="]",U=K[3];if(X)Y=Y|0;if(U===void 0||U==="["&&H+2===W){oZ($,U===void 0?new qW(Y,J,Q):new FW(Y,J,Q));break}else{let N=$.map[Y];if(N===void 0)N=new DW(Y),oZ($,N);$=N}}}class g8{constructor(J,Q){this.seq=[],this.map={};let $=J.getProgramParameter(Q,J.ACTIVE_UNIFORMS);for(let K=0;K<$;++K){let H=J.getActiveUniform(Q,K),Y=J.getUniformLocation(Q,H.name);ZU(H,Y,this)}let Z=[],W=[];for(let K of this.seq)if(K.type===J.SAMPLER_2D_SHADOW||K.type===J.SAMPLER_CUBE_SHADOW||K.type===J.SAMPLER_2D_ARRAY_SHADOW)Z.push(K);else W.push(K);if(Z.length>0)this.seq=Z.concat(W)}setValue(J,Q,$,Z){let W=this.map[Q];if(W!==void 0)W.setValue(J,$,Z)}setOptional(J,Q,$){let Z=Q[$];if(Z!==void 0)this.setValue(J,$,Z)}static upload(J,Q,$,Z){for(let W=0,K=Q.length;W!==K;++W){let H=Q[W],Y=$[H.id];if(Y.needsUpdate!==!1)H.setValue(J,Y.value,Z)}}static seqWithValue(J,Q){let $=[];for(let Z=0,W=J.length;Z!==W;++Z){let K=J[Z];if(K.id in Q)$.push(K)}return $}}function aZ(J,Q,$){let Z=J.createShader(Q);return J.shaderSource(Z,$),J.compileShader(Z),Z}var WU=37297,KU=0;function HU(J,Q){let $=J.split(`
`),Z=[],W=Math.max(Q-6,0),K=Math.min(Q+6,$.length);for(let H=W;H<K;H++){let Y=H+1;Z.push(`${Y===Q?">":" "} ${Y}: ${$[H]}`)}return Z.join(`
`)}var rZ=new P0;function YU(J){h0._getMatrix(rZ,h0.workingColorSpace,J);let Q=`mat3( ${rZ.elements.map(($)=>$.toFixed(4))} )`;switch(h0.getTransfer(J)){case EQ:return[Q,"LinearTransferOETF"];case r0:return[Q,"sRGBTransferOETF"];default:return C0("WebGLProgram: Unsupported color space: ",J),[Q,"LinearTransferOETF"]}}function tZ(J,Q,$){let Z=J.getShaderParameter(Q,J.COMPILE_STATUS),K=(J.getShaderInfoLog(Q)||"").trim();if(Z&&K==="")return"";let H=/ERROR: 0:(\d+)/.exec(K);if(H){let Y=parseInt(H[1]);return $.toUpperCase()+`

`+K+`

`+HU(J.getShaderSource(Q),Y)}else return K}function XU(J,Q){let $=YU(Q);return[`vec4 ${J}( vec4 value ) {`,`	return ${$[1]}( vec4( value.rgb * ${$[0]}, value.a ) );`,"}"].join(`
`)}var UU={[L7]:"Linear",[V7]:"Reinhard",[B7]:"Cineon",[z7]:"ACESFilmic",[A7]:"AgX",[w7]:"Neutral",[I7]:"Custom"};function GU(J,Q){let $=UU[Q];if($===void 0)return C0("WebGLProgram: Unsupported toneMapping:",Q),"vec3 "+J+"( vec3 color ) { return LinearToneMapping( color ); }";return"vec3 "+J+"( vec3 color ) { return "+$+"ToneMapping( color ); }"}var g6=new b;function EU(){h0.getLuminanceCoefficients(g6);let J=g6.x.toFixed(4),Q=g6.y.toFixed(4),$=g6.z.toFixed(4);return["float luminance( const in vec3 rgb ) {",`	const vec3 weights = vec3( ${J}, ${Q}, ${$} );`,"\treturn dot( weights, rgb );","}"].join(`
`)}function NU(J){return[J.extensionClipCullDistance?"#extension GL_ANGLE_clip_cull_distance : require":"",J.extensionMultiDraw?"#extension GL_ANGLE_multi_draw : require":""].filter(x8).join(`
`)}function qU(J){let Q=[];for(let $ in J){let Z=J[$];if(Z===!1)continue;Q.push("#define "+$+" "+Z)}return Q.join(`
`)}function FU(J,Q){let $={},Z=J.getProgramParameter(Q,J.ACTIVE_ATTRIBUTES);for(let W=0;W<Z;W++){let K=J.getActiveAttrib(Q,W),H=K.name,Y=1;if(K.type===J.FLOAT_MAT2)Y=2;if(K.type===J.FLOAT_MAT3)Y=3;if(K.type===J.FLOAT_MAT4)Y=4;$[H]={type:K.type,location:J.getAttribLocation(Q,H),locationSize:Y}}return $}function x8(J){return J!==""}function eZ(J,Q){let $=Q.numSpotLightShadows+Q.numSpotLightMaps-Q.numSpotLightShadowsWithMaps;return J.replace(/NUM_DIR_LIGHTS/g,Q.numDirLights).replace(/NUM_SPOT_LIGHTS/g,Q.numSpotLights).replace(/NUM_SPOT_LIGHT_MAPS/g,Q.numSpotLightMaps).replace(/NUM_SPOT_LIGHT_COORDS/g,$).replace(/NUM_RECT_AREA_LIGHTS/g,Q.numRectAreaLights).replace(/NUM_POINT_LIGHTS/g,Q.numPointLights).replace(/NUM_HEMI_LIGHTS/g,Q.numHemiLights).replace(/NUM_DIR_LIGHT_SHADOWS/g,Q.numDirLightShadows).replace(/NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS/g,Q.numSpotLightShadowsWithMaps).replace(/NUM_SPOT_LIGHT_SHADOWS/g,Q.numSpotLightShadows).replace(/NUM_POINT_LIGHT_SHADOWS/g,Q.numPointLightShadows)}function JW(J,Q){return J.replace(/NUM_CLIPPING_PLANES/g,Q.numClippingPlanes).replace(/UNION_CLIPPING_PLANES/g,Q.numClippingPlanes-Q.numClipIntersection)}var DU=/^[ \t]*#include +<([\w\d./]+)>/gm;function oQ(J){return J.replace(DU,OU)}var RU=new Map;function OU(J,Q){let $=j0[Q];if($===void 0){let Z=RU.get(Q);if(Z!==void 0)$=j0[Z],C0('WebGLRenderer: Shader chunk "%s" has been deprecated. Use "%s" instead.',Q,Z);else throw Error("THREE.WebGLProgram: Can not resolve #include <"+Q+">")}return oQ($)}var kU=/#pragma unroll_loop_start\s+for\s*\(\s*int\s+i\s*=\s*(\d+)\s*;\s*i\s*<\s*(\d+)\s*;\s*i\s*\+\+\s*\)\s*{([\s\S]+?)}\s+#pragma unroll_loop_end/g;function QW(J){return J.replace(kU,MU)}function MU(J,Q,$,Z){let W="";for(let K=parseInt(Q);K<parseInt($);K++)W+=Z.replace(/\[\s*i\s*\]/g,"[ "+K+" ]").replace(/UNROLLED_LOOP_INDEX/g,K);return W}function $W(J){let Q=`precision ${J.precision} float;
	precision ${J.precision} int;
	precision ${J.precision} sampler2D;
	precision ${J.precision} samplerCube;
	precision ${J.precision} sampler3D;
	precision ${J.precision} sampler2DArray;
	precision ${J.precision} sampler2DShadow;
	precision ${J.precision} samplerCubeShadow;
	precision ${J.precision} sampler2DArrayShadow;
	precision ${J.precision} isampler2D;
	precision ${J.precision} isampler3D;
	precision ${J.precision} isamplerCube;
	precision ${J.precision} isampler2DArray;
	precision ${J.precision} usampler2D;
	precision ${J.precision} usampler3D;
	precision ${J.precision} usamplerCube;
	precision ${J.precision} usampler2DArray;
	`;if(J.precision==="highp")Q+=`
#define HIGH_PRECISION`;else if(J.precision==="mediump")Q+=`
#define MEDIUM_PRECISION`;else if(J.precision==="lowp")Q+=`
#define LOW_PRECISION`;return Q}var LU={[w8]:"SHADOWMAP_TYPE_PCF",[E8]:"SHADOWMAP_TYPE_VSM"};function VU(J){return LU[J.shadowMapType]||"SHADOWMAP_TYPE_BASIC"}var BU={[F8]:"ENVMAP_TYPE_CUBE",[b9]:"ENVMAP_TYPE_CUBE",[_8]:"ENVMAP_TYPE_CUBE_UV"};function zU(J){if(J.envMap===!1)return"ENVMAP_TYPE_CUBE";return BU[J.envMapMode]||"ENVMAP_TYPE_CUBE"}var IU={[b9]:"ENVMAP_MODE_REFRACTION"};function AU(J){if(J.envMap===!1)return"ENVMAP_MODE_REFLECTION";return IU[J.envMapMode]||"ENVMAP_MODE_REFLECTION"}var wU={[GZ]:"ENVMAP_BLENDING_MULTIPLY",[EZ]:"ENVMAP_BLENDING_MIX",[NZ]:"ENVMAP_BLENDING_ADD"};function CU(J){if(J.envMap===!1)return"ENVMAP_BLENDING_NONE";return wU[J.combine]||"ENVMAP_BLENDING_NONE"}function _U(J){let Q=J.envMapCubeUVHeight;if(Q===null)return null;let $=Math.log2(Q)-2,Z=1/Q;return{texelWidth:1/(3*Math.max(Math.pow(2,$),112)),texelHeight:Z,maxMip:$}}function PU(J,Q,$,Z){let W=J.getContext(),K=$.defines,H=$.vertexShader,Y=$.fragmentShader,X=VU($),U=zU($),E=AU($),N=CU($),G=_U($),D=NU($),M=qU(K),z=W.createProgram(),F,q,_=$.glslVersion?"#version "+$.glslVersion+`
`:"";if($.isRawShaderMaterial){if(F=["#define SHADER_TYPE "+$.shaderType,"#define SHADER_NAME "+$.shaderName,M].filter(x8).join(`
`),F.length>0)F+=`
`;if(q=["#define SHADER_TYPE "+$.shaderType,"#define SHADER_NAME "+$.shaderName,M].filter(x8).join(`
`),q.length>0)q+=`
`}else F=[$W($),"#define SHADER_TYPE "+$.shaderType,"#define SHADER_NAME "+$.shaderName,M,$.extensionClipCullDistance?"#define USE_CLIP_DISTANCE":"",$.batching?"#define USE_BATCHING":"",$.batchingColor?"#define USE_BATCHING_COLOR":"",$.instancing?"#define USE_INSTANCING":"",$.instancingColor?"#define USE_INSTANCING_COLOR":"",$.instancingMorph?"#define USE_INSTANCING_MORPH":"",$.useFog&&$.fog?"#define USE_FOG":"",$.useFog&&$.fogExp2?"#define FOG_EXP2":"",$.map?"#define USE_MAP":"",$.envMap?"#define USE_ENVMAP":"",$.envMap?"#define "+E:"",$.lightMap?"#define USE_LIGHTMAP":"",$.aoMap?"#define USE_AOMAP":"",$.bumpMap?"#define USE_BUMPMAP":"",$.normalMap?"#define USE_NORMALMAP":"",$.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",$.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",$.displacementMap?"#define USE_DISPLACEMENTMAP":"",$.emissiveMap?"#define USE_EMISSIVEMAP":"",$.anisotropy?"#define USE_ANISOTROPY":"",$.anisotropyMap?"#define USE_ANISOTROPYMAP":"",$.clearcoatMap?"#define USE_CLEARCOATMAP":"",$.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",$.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",$.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",$.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",$.specularMap?"#define USE_SPECULARMAP":"",$.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",$.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",$.roughnessMap?"#define USE_ROUGHNESSMAP":"",$.metalnessMap?"#define USE_METALNESSMAP":"",$.alphaMap?"#define USE_ALPHAMAP":"",$.alphaHash?"#define USE_ALPHAHASH":"",$.transmission?"#define USE_TRANSMISSION":"",$.transmissionMap?"#define USE_TRANSMISSIONMAP":"",$.thicknessMap?"#define USE_THICKNESSMAP":"",$.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",$.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",$.mapUv?"#define MAP_UV "+$.mapUv:"",$.alphaMapUv?"#define ALPHAMAP_UV "+$.alphaMapUv:"",$.lightMapUv?"#define LIGHTMAP_UV "+$.lightMapUv:"",$.aoMapUv?"#define AOMAP_UV "+$.aoMapUv:"",$.emissiveMapUv?"#define EMISSIVEMAP_UV "+$.emissiveMapUv:"",$.bumpMapUv?"#define BUMPMAP_UV "+$.bumpMapUv:"",$.normalMapUv?"#define NORMALMAP_UV "+$.normalMapUv:"",$.displacementMapUv?"#define DISPLACEMENTMAP_UV "+$.displacementMapUv:"",$.metalnessMapUv?"#define METALNESSMAP_UV "+$.metalnessMapUv:"",$.roughnessMapUv?"#define ROUGHNESSMAP_UV "+$.roughnessMapUv:"",$.anisotropyMapUv?"#define ANISOTROPYMAP_UV "+$.anisotropyMapUv:"",$.clearcoatMapUv?"#define CLEARCOATMAP_UV "+$.clearcoatMapUv:"",$.clearcoatNormalMapUv?"#define CLEARCOAT_NORMALMAP_UV "+$.clearcoatNormalMapUv:"",$.clearcoatRoughnessMapUv?"#define CLEARCOAT_ROUGHNESSMAP_UV "+$.clearcoatRoughnessMapUv:"",$.iridescenceMapUv?"#define IRIDESCENCEMAP_UV "+$.iridescenceMapUv:"",$.iridescenceThicknessMapUv?"#define IRIDESCENCE_THICKNESSMAP_UV "+$.iridescenceThicknessMapUv:"",$.sheenColorMapUv?"#define SHEEN_COLORMAP_UV "+$.sheenColorMapUv:"",$.sheenRoughnessMapUv?"#define SHEEN_ROUGHNESSMAP_UV "+$.sheenRoughnessMapUv:"",$.specularMapUv?"#define SPECULARMAP_UV "+$.specularMapUv:"",$.specularColorMapUv?"#define SPECULAR_COLORMAP_UV "+$.specularColorMapUv:"",$.specularIntensityMapUv?"#define SPECULAR_INTENSITYMAP_UV "+$.specularIntensityMapUv:"",$.transmissionMapUv?"#define TRANSMISSIONMAP_UV "+$.transmissionMapUv:"",$.thicknessMapUv?"#define THICKNESSMAP_UV "+$.thicknessMapUv:"",$.vertexTangents&&$.flatShading===!1?"#define USE_TANGENT":"",$.vertexNormals?"#define HAS_NORMAL":"",$.vertexColors?"#define USE_COLOR":"",$.vertexAlphas?"#define USE_COLOR_ALPHA":"",$.vertexUv1s?"#define USE_UV1":"",$.vertexUv2s?"#define USE_UV2":"",$.vertexUv3s?"#define USE_UV3":"",$.pointsUvs?"#define USE_POINTS_UV":"",$.flatShading?"#define FLAT_SHADED":"",$.skinning?"#define USE_SKINNING":"",$.morphTargets?"#define USE_MORPHTARGETS":"",$.morphNormals&&$.flatShading===!1?"#define USE_MORPHNORMALS":"",$.morphColors?"#define USE_MORPHCOLORS":"",$.morphTargetsCount>0?"#define MORPHTARGETS_TEXTURE_STRIDE "+$.morphTextureStride:"",$.morphTargetsCount>0?"#define MORPHTARGETS_COUNT "+$.morphTargetsCount:"",$.doubleSided?"#define DOUBLE_SIDED":"",$.flipSided?"#define FLIP_SIDED":"",$.shadowMapEnabled?"#define USE_SHADOWMAP":"",$.shadowMapEnabled?"#define "+X:"",$.sizeAttenuation?"#define USE_SIZEATTENUATION":"",$.numLightProbes>0?"#define USE_LIGHT_PROBES":"",$.logarithmicDepthBuffer?"#define USE_LOGARITHMIC_DEPTH_BUFFER":"",$.reversedDepthBuffer?"#define USE_REVERSED_DEPTH_BUFFER":"","uniform mat4 modelMatrix;","uniform mat4 modelViewMatrix;","uniform mat4 projectionMatrix;","uniform mat4 viewMatrix;","uniform mat3 normalMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;","#ifdef USE_INSTANCING","\tattribute mat4 instanceMatrix;","#endif","#ifdef USE_INSTANCING_COLOR","\tattribute vec3 instanceColor;","#endif","#ifdef USE_INSTANCING_MORPH","\tuniform sampler2D morphTexture;","#endif","attribute vec3 position;","attribute vec3 normal;","attribute vec2 uv;","#ifdef USE_UV1","\tattribute vec2 uv1;","#endif","#ifdef USE_UV2","\tattribute vec2 uv2;","#endif","#ifdef USE_UV3","\tattribute vec2 uv3;","#endif","#ifdef USE_TANGENT","\tattribute vec4 tangent;","#endif","#if defined( USE_COLOR_ALPHA )","\tattribute vec4 color;","#elif defined( USE_COLOR )","\tattribute vec3 color;","#endif","#ifdef USE_SKINNING","\tattribute vec4 skinIndex;","\tattribute vec4 skinWeight;","#endif",`
`].filter(x8).join(`
`),q=[$W($),"#define SHADER_TYPE "+$.shaderType,"#define SHADER_NAME "+$.shaderName,M,$.useFog&&$.fog?"#define USE_FOG":"",$.useFog&&$.fogExp2?"#define FOG_EXP2":"",$.alphaToCoverage?"#define ALPHA_TO_COVERAGE":"",$.map?"#define USE_MAP":"",$.matcap?"#define USE_MATCAP":"",$.envMap?"#define USE_ENVMAP":"",$.envMap?"#define "+U:"",$.envMap?"#define "+E:"",$.envMap?"#define "+N:"",G?"#define CUBEUV_TEXEL_WIDTH "+G.texelWidth:"",G?"#define CUBEUV_TEXEL_HEIGHT "+G.texelHeight:"",G?"#define CUBEUV_MAX_MIP "+G.maxMip+".0":"",$.lightMap?"#define USE_LIGHTMAP":"",$.aoMap?"#define USE_AOMAP":"",$.bumpMap?"#define USE_BUMPMAP":"",$.normalMap?"#define USE_NORMALMAP":"",$.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",$.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",$.packedNormalMap?"#define USE_PACKED_NORMALMAP":"",$.emissiveMap?"#define USE_EMISSIVEMAP":"",$.anisotropy?"#define USE_ANISOTROPY":"",$.anisotropyMap?"#define USE_ANISOTROPYMAP":"",$.clearcoat?"#define USE_CLEARCOAT":"",$.clearcoatMap?"#define USE_CLEARCOATMAP":"",$.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",$.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",$.dispersion?"#define USE_DISPERSION":"",$.iridescence?"#define USE_IRIDESCENCE":"",$.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",$.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",$.specularMap?"#define USE_SPECULARMAP":"",$.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",$.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",$.roughnessMap?"#define USE_ROUGHNESSMAP":"",$.metalnessMap?"#define USE_METALNESSMAP":"",$.alphaMap?"#define USE_ALPHAMAP":"",$.alphaTest?"#define USE_ALPHATEST":"",$.alphaHash?"#define USE_ALPHAHASH":"",$.sheen?"#define USE_SHEEN":"",$.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",$.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",$.transmission?"#define USE_TRANSMISSION":"",$.transmissionMap?"#define USE_TRANSMISSIONMAP":"",$.thicknessMap?"#define USE_THICKNESSMAP":"",$.vertexTangents&&$.flatShading===!1?"#define USE_TANGENT":"",$.vertexColors||$.instancingColor?"#define USE_COLOR":"",$.vertexAlphas||$.batchingColor?"#define USE_COLOR_ALPHA":"",$.vertexUv1s?"#define USE_UV1":"",$.vertexUv2s?"#define USE_UV2":"",$.vertexUv3s?"#define USE_UV3":"",$.pointsUvs?"#define USE_POINTS_UV":"",$.gradientMap?"#define USE_GRADIENTMAP":"",$.flatShading?"#define FLAT_SHADED":"",$.doubleSided?"#define DOUBLE_SIDED":"",$.flipSided?"#define FLIP_SIDED":"",$.shadowMapEnabled?"#define USE_SHADOWMAP":"",$.shadowMapEnabled?"#define "+X:"",$.premultipliedAlpha?"#define PREMULTIPLIED_ALPHA":"",$.numLightProbes>0?"#define USE_LIGHT_PROBES":"",$.numLightProbeGrids>0?"#define USE_LIGHT_PROBES_GRID":"",$.decodeVideoTexture?"#define DECODE_VIDEO_TEXTURE":"",$.decodeVideoTextureEmissive?"#define DECODE_VIDEO_TEXTURE_EMISSIVE":"",$.logarithmicDepthBuffer?"#define USE_LOGARITHMIC_DEPTH_BUFFER":"",$.reversedDepthBuffer?"#define USE_REVERSED_DEPTH_BUFFER":"","uniform mat4 viewMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;",$.toneMapping!==cJ?"#define TONE_MAPPING":"",$.toneMapping!==cJ?j0.tonemapping_pars_fragment:"",$.toneMapping!==cJ?GU("toneMapping",$.toneMapping):"",$.dithering?"#define DITHERING":"",$.opaque?"#define OPAQUE":"",j0.colorspace_pars_fragment,XU("linearToOutputTexel",$.outputColorSpace),EU(),$.useDepthPacking?"#define DEPTH_PACKING "+$.depthPacking:"",`
`].filter(x8).join(`
`);if(H=oQ(H),H=eZ(H,$),H=JW(H,$),Y=oQ(Y),Y=eZ(Y,$),Y=JW(Y,$),H=QW(H),Y=QW(Y),$.isRawShaderMaterial!==!0)_=`#version 300 es
`,F=[D,"#define attribute in","#define varying out","#define texture2D texture"].join(`
`)+`
`+F,q=["#define varying in",$.glslVersion===NQ?"":"layout(location = 0) out highp vec4 pc_fragColor;",$.glslVersion===NQ?"":"#define gl_FragColor pc_fragColor","#define gl_FragDepthEXT gl_FragDepth","#define texture2D texture","#define textureCube texture","#define texture2DProj textureProj","#define texture2DLodEXT textureLod","#define texture2DProjLodEXT textureProjLod","#define textureCubeLodEXT textureLod","#define texture2DGradEXT textureGrad","#define texture2DProjGradEXT textureProjGrad","#define textureCubeGradEXT textureGrad"].join(`
`)+`
`+q;let w=_+F+H,V=_+q+Y,A=aZ(W,W.VERTEX_SHADER,w),I=aZ(W,W.FRAGMENT_SHADER,V);if(W.attachShader(z,A),W.attachShader(z,I),$.index0AttributeName!==void 0)W.bindAttribLocation(z,0,$.index0AttributeName);else if($.hasPositionAttribute===!0)W.bindAttribLocation(z,0,"position");W.linkProgram(z);function P(C){if(J.debug.checkShaderErrors){let m=W.getProgramInfoLog(z)||"",o=W.getShaderInfoLog(A)||"",p=W.getShaderInfoLog(I)||"",n=m.trim(),u=o.trim(),h=p.trim(),t=!0,e=!0;if(W.getProgramParameter(z,W.LINK_STATUS)===!1)if(t=!1,typeof J.debug.onShaderError==="function")J.debug.onShaderError(W,z,A,I);else{let H0=tZ(W,A,"vertex"),M0=tZ(W,I,"fragment");_0("WebGLProgram: Shader Error "+W.getError()+" - VALIDATE_STATUS "+W.getProgramParameter(z,W.VALIDATE_STATUS)+`

Material Name: `+C.name+`
Material Type: `+C.type+`

Program Info Log: `+n+`
`+H0+`
`+M0)}else if(n!=="")C0("WebGLProgram: Program Info Log:",n);else if(u===""||h==="")e=!1;if(e)C.diagnostics={runnable:t,programLog:n,vertexShader:{log:u,prefix:F},fragmentShader:{log:h,prefix:q}}}W.deleteShader(A),W.deleteShader(I),O=new g8(W,z),B=FU(W,z)}let O;this.getUniforms=function(){if(O===void 0)P(this);return O};let B;this.getAttributes=function(){if(B===void 0)P(this);return B};let l=$.rendererExtensionParallelShaderCompile===!1;return this.isReady=function(){if(l===!1)l=W.getProgramParameter(z,WU);return l},this.destroy=function(){Z.releaseStatesOfProgram(this),W.deleteProgram(z),this.program=void 0},this.type=$.shaderType,this.name=$.shaderName,this.id=KU++,this.cacheKey=Q,this.usedTimes=1,this.program=z,this.vertexShader=A,this.fragmentShader=I,this}var TU=0;class RW{constructor(){this.shaderCache=new Map,this.materialCache=new Map}update(J,Q,$){let Z=this._getShaderCacheForMaterial(J);if(Z.has(Q)===!1)Z.add(Q),Q.usedTimes++;if(Z.has($)===!1)Z.add($),$.usedTimes++;return this}remove(J){let Q=this.materialCache.get(J);for(let $ of Q)if($.usedTimes--,$.usedTimes===0)this.shaderCache.delete($.code);return this.materialCache.delete(J),this}getVertexShaderStage(J){return this._getShaderStage(J.vertexShader)}getFragmentShaderStage(J){return this._getShaderStage(J.fragmentShader)}dispose(){this.shaderCache.clear(),this.materialCache.clear()}_getShaderCacheForMaterial(J){let Q=this.materialCache,$=Q.get(J);if($===void 0)$=new Set,Q.set(J,$);return $}_getShaderStage(J){let Q=this.shaderCache,$=Q.get(J);if($===void 0)$=new OW(J),Q.set(J,$);return $}}class OW{constructor(J){this.id=TU++,this.code=J,this.usedTimes=0}}function SU(J){return J===p9||J===M6||J===L6}function jU(J,Q,$,Z,W,K){let H=new I6,Y=new RW,X=new Set,U=[],E=new Map,N=Z.logarithmicDepthBuffer,G=Z.precision,D={MeshDepthMaterial:"depth",MeshDistanceMaterial:"distance",MeshNormalMaterial:"normal",MeshBasicMaterial:"basic",MeshLambertMaterial:"lambert",MeshPhongMaterial:"phong",MeshToonMaterial:"toon",MeshStandardMaterial:"physical",MeshPhysicalMaterial:"physical",MeshMatcapMaterial:"matcap",LineBasicMaterial:"basic",LineDashedMaterial:"dashed",PointsMaterial:"points",ShadowMaterial:"shadow",SpriteMaterial:"sprite"};function M(O){if(X.add(O),O===0)return"uv";return`uv${O}`}function z(O,B,l,C,m,o){let p=C.fog,n=m.geometry,u=O.isMeshStandardMaterial||O.isMeshLambertMaterial||O.isMeshPhongMaterial?C.environment:null,h=O.isMeshStandardMaterial||O.isMeshLambertMaterial&&!O.envMap||O.isMeshPhongMaterial&&!O.envMap,t=Q.get(O.envMap||u,h),e=!!t&&t.mapping===_8?t.image.height:null,H0=D[O.type];if(O.precision!==null){if(G=Z.getMaxPrecision(O.precision),G!==O.precision)C0("WebGLProgram.getParameters:",O.precision,"not supported, using",G,"instead.")}let M0=n.morphAttributes.position||n.morphAttributes.normal||n.morphAttributes.color,k0=M0!==void 0?M0.length:0,ZJ=0;if(n.morphAttributes.position!==void 0)ZJ=1;if(n.morphAttributes.normal!==void 0)ZJ=2;if(n.morphAttributes.color!==void 0)ZJ=3;let i0,i,Z0,F0;if(H0){let T0=Q9[H0];i0=T0.vertexShader,i=T0.fragmentShader}else{i0=O.vertexShader,i=O.fragmentShader;let T0=Y.getVertexShaderStage(O),HJ=Y.getFragmentShaderStage(O);Y.update(O,T0,HJ),Z0=T0.id,F0=HJ.id}let D0=J.getRenderTarget(),w0=J.state.buffers.depth.getReversed(),p0=m.isInstancedMesh===!0,f0=m.isBatchedMesh===!0,v0=!!O.map,t0=!!O.matcap,m0=!!t,b0=!!O.aoMap,FJ=!!O.lightMap,yJ=!!O.bumpMap&&O.wireframe===!1,QJ=!!O.normalMap,OJ=!!O.displacementMap,DJ=!!O.emissiveMap,EJ=!!O.metalnessMap,j=!!O.roughnessMap,fJ=O.anisotropy>0,c0=O.clearcoat>0,$J=O.dispersion>0,L=O.iridescence>0,R=O.sheen>0,T=O.transmission>0,g=fJ&&!!O.anisotropyMap,r=c0&&!!O.clearcoatMap,J0=c0&&!!O.clearcoatNormalMap,Y0=c0&&!!O.clearcoatRoughnessMap,d=L&&!!O.iridescenceMap,s=L&&!!O.iridescenceThicknessMap,N0=R&&!!O.sheenColorMap,V0=R&&!!O.sheenRoughnessMap,X0=!!O.specularMap,Q0=!!O.specularColorMap,I0=!!O.specularIntensityMap,A0=T&&!!O.transmissionMap,l0=T&&!!O.thicknessMap,S=!!O.gradientMap,$0=!!O.alphaMap,c=O.alphaTest>0,W0=!!O.alphaHash,q0=!!O.extensions,a=cJ;if(O.toneMapped){if(D0===null||D0.isXRRenderTarget===!0)a=J.toneMapping}let K0={shaderID:H0,shaderType:O.type,shaderName:O.name,vertexShader:i0,fragmentShader:i,defines:O.defines,customVertexShaderID:Z0,customFragmentShaderID:F0,isRawShaderMaterial:O.isRawShaderMaterial===!0,glslVersion:O.glslVersion,precision:G,batching:f0,batchingColor:f0&&m._colorsTexture!==null,instancing:p0,instancingColor:p0&&m.instanceColor!==null,instancingMorph:p0&&m.morphTexture!==null,outputColorSpace:D0===null?J.outputColorSpace:D0.isXRRenderTarget===!0?D0.texture.colorSpace:h0.workingColorSpace,alphaToCoverage:!!O.alphaToCoverage,map:v0,matcap:t0,envMap:m0,envMapMode:m0&&t.mapping,envMapCubeUVHeight:e,aoMap:b0,lightMap:FJ,bumpMap:yJ,normalMap:QJ,displacementMap:OJ,emissiveMap:DJ,normalMapObjectSpace:QJ&&O.normalMapType===zZ,normalMapTangentSpace:QJ&&O.normalMapType===UQ,packedNormalMap:QJ&&O.normalMapType===UQ&&SU(O.normalMap.format),metalnessMap:EJ,roughnessMap:j,anisotropy:fJ,anisotropyMap:g,clearcoat:c0,clearcoatMap:r,clearcoatNormalMap:J0,clearcoatRoughnessMap:Y0,dispersion:$J,iridescence:L,iridescenceMap:d,iridescenceThicknessMap:s,sheen:R,sheenColorMap:N0,sheenRoughnessMap:V0,specularMap:X0,specularColorMap:Q0,specularIntensityMap:I0,transmission:T,transmissionMap:A0,thicknessMap:l0,gradientMap:S,opaque:O.transparent===!1&&O.blending===C8&&O.alphaToCoverage===!1,alphaMap:$0,alphaTest:c,alphaHash:W0,combine:O.combine,mapUv:v0&&M(O.map.channel),aoMapUv:b0&&M(O.aoMap.channel),lightMapUv:FJ&&M(O.lightMap.channel),bumpMapUv:yJ&&M(O.bumpMap.channel),normalMapUv:QJ&&M(O.normalMap.channel),displacementMapUv:OJ&&M(O.displacementMap.channel),emissiveMapUv:DJ&&M(O.emissiveMap.channel),metalnessMapUv:EJ&&M(O.metalnessMap.channel),roughnessMapUv:j&&M(O.roughnessMap.channel),anisotropyMapUv:g&&M(O.anisotropyMap.channel),clearcoatMapUv:r&&M(O.clearcoatMap.channel),clearcoatNormalMapUv:J0&&M(O.clearcoatNormalMap.channel),clearcoatRoughnessMapUv:Y0&&M(O.clearcoatRoughnessMap.channel),iridescenceMapUv:d&&M(O.iridescenceMap.channel),iridescenceThicknessMapUv:s&&M(O.iridescenceThicknessMap.channel),sheenColorMapUv:N0&&M(O.sheenColorMap.channel),sheenRoughnessMapUv:V0&&M(O.sheenRoughnessMap.channel),specularMapUv:X0&&M(O.specularMap.channel),specularColorMapUv:Q0&&M(O.specularColorMap.channel),specularIntensityMapUv:I0&&M(O.specularIntensityMap.channel),transmissionMapUv:A0&&M(O.transmissionMap.channel),thicknessMapUv:l0&&M(O.thicknessMap.channel),alphaMapUv:$0&&M(O.alphaMap.channel),vertexTangents:!!n.attributes.tangent&&(QJ||fJ),vertexNormals:!!n.attributes.normal,vertexColors:O.vertexColors,vertexAlphas:O.vertexColors===!0&&!!n.attributes.color&&n.attributes.color.itemSize===4,pointsUvs:m.isPoints===!0&&!!n.attributes.uv&&(v0||$0),fog:!!p,useFog:O.fog===!0,fogExp2:!!p&&p.isFogExp2,flatShading:O.wireframe===!1&&(O.flatShading===!0||n.attributes.normal===void 0&&QJ===!1&&(O.isMeshLambertMaterial||O.isMeshPhongMaterial||O.isMeshStandardMaterial||O.isMeshPhysicalMaterial)),sizeAttenuation:O.sizeAttenuation===!0,logarithmicDepthBuffer:N,reversedDepthBuffer:w0,skinning:m.isSkinnedMesh===!0,hasPositionAttribute:n.attributes.position!==void 0,morphTargets:n.morphAttributes.position!==void 0,morphNormals:n.morphAttributes.normal!==void 0,morphColors:n.morphAttributes.color!==void 0,morphTargetsCount:k0,morphTextureStride:ZJ,numDirLights:B.directional.length,numPointLights:B.point.length,numSpotLights:B.spot.length,numSpotLightMaps:B.spotLightMap.length,numRectAreaLights:B.rectArea.length,numHemiLights:B.hemi.length,numDirLightShadows:B.directionalShadowMap.length,numPointLightShadows:B.pointShadowMap.length,numSpotLightShadows:B.spotShadowMap.length,numSpotLightShadowsWithMaps:B.numSpotLightShadowsWithMaps,numLightProbes:B.numLightProbes,numLightProbeGrids:o.length,numClippingPlanes:K.numPlanes,numClipIntersection:K.numIntersection,dithering:O.dithering,shadowMapEnabled:J.shadowMap.enabled&&l.length>0,shadowMapType:J.shadowMap.type,toneMapping:a,decodeVideoTexture:v0&&O.map.isVideoTexture===!0&&h0.getTransfer(O.map.colorSpace)===r0,decodeVideoTextureEmissive:DJ&&O.emissiveMap.isVideoTexture===!0&&h0.getTransfer(O.emissiveMap.colorSpace)===r0,premultipliedAlpha:O.premultipliedAlpha,doubleSided:O.side===rJ,flipSided:O.side===CJ,useDepthPacking:O.depthPacking>=0,depthPacking:O.depthPacking||0,index0AttributeName:O.index0AttributeName,extensionClipCullDistance:q0&&O.extensions.clipCullDistance===!0&&$.has("WEBGL_clip_cull_distance"),extensionMultiDraw:(q0&&O.extensions.multiDraw===!0||f0)&&$.has("WEBGL_multi_draw"),rendererExtensionParallelShaderCompile:$.has("KHR_parallel_shader_compile"),customProgramCacheKey:O.customProgramCacheKey()};return K0.vertexUv1s=X.has(1),K0.vertexUv2s=X.has(2),K0.vertexUv3s=X.has(3),X.clear(),K0}function F(O){let B=[];if(O.shaderID)B.push(O.shaderID);else B.push(O.customVertexShaderID),B.push(O.customFragmentShaderID);if(O.defines!==void 0)for(let l in O.defines)B.push(l),B.push(O.defines[l]);if(O.isRawShaderMaterial===!1)q(B,O),_(B,O),B.push(J.outputColorSpace);return B.push(O.customProgramCacheKey),B.join()}function q(O,B){O.push(B.precision),O.push(B.outputColorSpace),O.push(B.envMapMode),O.push(B.envMapCubeUVHeight),O.push(B.mapUv),O.push(B.alphaMapUv),O.push(B.lightMapUv),O.push(B.aoMapUv),O.push(B.bumpMapUv),O.push(B.normalMapUv),O.push(B.displacementMapUv),O.push(B.emissiveMapUv),O.push(B.metalnessMapUv),O.push(B.roughnessMapUv),O.push(B.anisotropyMapUv),O.push(B.clearcoatMapUv),O.push(B.clearcoatNormalMapUv),O.push(B.clearcoatRoughnessMapUv),O.push(B.iridescenceMapUv),O.push(B.iridescenceThicknessMapUv),O.push(B.sheenColorMapUv),O.push(B.sheenRoughnessMapUv),O.push(B.specularMapUv),O.push(B.specularColorMapUv),O.push(B.specularIntensityMapUv),O.push(B.transmissionMapUv),O.push(B.thicknessMapUv),O.push(B.combine),O.push(B.fogExp2),O.push(B.sizeAttenuation),O.push(B.morphTargetsCount),O.push(B.morphAttributeCount),O.push(B.numDirLights),O.push(B.numPointLights),O.push(B.numSpotLights),O.push(B.numSpotLightMaps),O.push(B.numHemiLights),O.push(B.numRectAreaLights),O.push(B.numDirLightShadows),O.push(B.numPointLightShadows),O.push(B.numSpotLightShadows),O.push(B.numSpotLightShadowsWithMaps),O.push(B.numLightProbes),O.push(B.shadowMapType),O.push(B.toneMapping),O.push(B.numClippingPlanes),O.push(B.numClipIntersection),O.push(B.depthPacking)}function _(O,B){if(H.disableAll(),B.instancing)H.enable(0);if(B.instancingColor)H.enable(1);if(B.instancingMorph)H.enable(2);if(B.matcap)H.enable(3);if(B.envMap)H.enable(4);if(B.normalMapObjectSpace)H.enable(5);if(B.normalMapTangentSpace)H.enable(6);if(B.clearcoat)H.enable(7);if(B.iridescence)H.enable(8);if(B.alphaTest)H.enable(9);if(B.vertexColors)H.enable(10);if(B.vertexAlphas)H.enable(11);if(B.vertexUv1s)H.enable(12);if(B.vertexUv2s)H.enable(13);if(B.vertexUv3s)H.enable(14);if(B.vertexTangents)H.enable(15);if(B.anisotropy)H.enable(16);if(B.alphaHash)H.enable(17);if(B.batching)H.enable(18);if(B.dispersion)H.enable(19);if(B.batchingColor)H.enable(20);if(B.gradientMap)H.enable(21);if(B.packedNormalMap)H.enable(22);if(B.vertexNormals)H.enable(23);if(O.push(H.mask),H.disableAll(),B.fog)H.enable(0);if(B.useFog)H.enable(1);if(B.flatShading)H.enable(2);if(B.logarithmicDepthBuffer)H.enable(3);if(B.reversedDepthBuffer)H.enable(4);if(B.skinning)H.enable(5);if(B.morphTargets)H.enable(6);if(B.morphNormals)H.enable(7);if(B.morphColors)H.enable(8);if(B.premultipliedAlpha)H.enable(9);if(B.shadowMapEnabled)H.enable(10);if(B.doubleSided)H.enable(11);if(B.flipSided)H.enable(12);if(B.useDepthPacking)H.enable(13);if(B.dithering)H.enable(14);if(B.transmission)H.enable(15);if(B.sheen)H.enable(16);if(B.opaque)H.enable(17);if(B.pointsUvs)H.enable(18);if(B.decodeVideoTexture)H.enable(19);if(B.decodeVideoTextureEmissive)H.enable(20);if(B.alphaToCoverage)H.enable(21);if(B.numLightProbeGrids>0)H.enable(22);if(B.hasPositionAttribute)H.enable(23);O.push(H.mask)}function w(O){let B=D[O.type],l;if(B){let C=Q9[B];l=bZ.clone(C.uniforms)}else l=O.uniforms;return l}function V(O,B){let l=E.get(B);if(l!==void 0)++l.usedTimes;else l=new PU(J,B,O,W),U.push(l),E.set(B,l);return l}function A(O){if(--O.usedTimes===0){let B=U.indexOf(O);U[B]=U[U.length-1],U.pop(),E.delete(O.cacheKey),O.destroy()}}function I(O){Y.remove(O)}function P(){Y.dispose()}return{getParameters:z,getProgramCacheKey:F,getUniforms:w,acquireProgram:V,releaseProgram:A,releaseShaderCache:I,programs:U,dispose:P}}function yU(){let J=new WeakMap;function Q(H){return J.has(H)}function $(H){let Y=J.get(H);if(Y===void 0)Y={},J.set(H,Y);return Y}function Z(H){J.delete(H)}function W(H,Y,X){J.get(H)[Y]=X}function K(){J=new WeakMap}return{has:Q,get:$,remove:Z,update:W,dispose:K}}function fU(J,Q){if(J.groupOrder!==Q.groupOrder)return J.groupOrder-Q.groupOrder;else if(J.renderOrder!==Q.renderOrder)return J.renderOrder-Q.renderOrder;else if(J.material.id!==Q.material.id)return J.material.id-Q.material.id;else if(J.materialVariant!==Q.materialVariant)return J.materialVariant-Q.materialVariant;else if(J.z!==Q.z)return J.z-Q.z;else return J.id-Q.id}function ZW(J,Q){if(J.groupOrder!==Q.groupOrder)return J.groupOrder-Q.groupOrder;else if(J.renderOrder!==Q.renderOrder)return J.renderOrder-Q.renderOrder;else if(J.z!==Q.z)return Q.z-J.z;else return J.id-Q.id}function WW(){let J=[],Q=0,$=[],Z=[],W=[];function K(){Q=0,$.length=0,Z.length=0,W.length=0}function H(G){let D=0;if(G.isInstancedMesh)D+=2;if(G.isSkinnedMesh)D+=1;return D}function Y(G,D,M,z,F,q){let _=J[Q];if(_===void 0)_={id:G.id,object:G,geometry:D,material:M,materialVariant:H(G),groupOrder:z,renderOrder:G.renderOrder,z:F,group:q},J[Q]=_;else _.id=G.id,_.object=G,_.geometry=D,_.material=M,_.materialVariant=H(G),_.groupOrder=z,_.renderOrder=G.renderOrder,_.z=F,_.group=q;return Q++,_}function X(G,D,M,z,F,q){let _=Y(G,D,M,z,F,q);if(M.transmission>0)Z.push(_);else if(M.transparent===!0)W.push(_);else $.push(_)}function U(G,D,M,z,F,q){let _=Y(G,D,M,z,F,q);if(M.transmission>0)Z.unshift(_);else if(M.transparent===!0)W.unshift(_);else $.unshift(_)}function E(G,D,M){if($.length>1)$.sort(G||fU);if(Z.length>1)Z.sort(D||ZW);if(W.length>1)W.sort(D||ZW);if(M)$.reverse(),Z.reverse(),W.reverse()}function N(){for(let G=Q,D=J.length;G<D;G++){let M=J[G];if(M.id===null)break;M.id=null,M.object=null,M.geometry=null,M.material=null,M.group=null}}return{opaque:$,transmissive:Z,transparent:W,init:K,push:X,unshift:U,finish:N,sort:E}}function vU(){let J=new WeakMap;function Q(Z,W){let K=J.get(Z),H;if(K===void 0)H=new WW,J.set(Z,[H]);else if(W>=K.length)H=new WW,K.push(H);else H=K[W];return H}function $(){J=new WeakMap}return{get:Q,dispose:$}}function bU(){let J={};return{get:function(Q){if(J[Q.id]!==void 0)return J[Q.id];let $;switch(Q.type){case"DirectionalLight":$={direction:new b,color:new g0};break;case"SpotLight":$={position:new b,direction:new b,color:new g0,distance:0,coneCos:0,penumbraCos:0,decay:0};break;case"PointLight":$={position:new b,color:new g0,distance:0,decay:0};break;case"HemisphereLight":$={direction:new b,skyColor:new g0,groundColor:new g0};break;case"RectAreaLight":$={color:new g0,position:new b,halfWidth:new b,halfHeight:new b};break}return J[Q.id]=$,$}}}function hU(){let J={};return{get:function(Q){if(J[Q.id]!==void 0)return J[Q.id];let $;switch(Q.type){case"DirectionalLight":$={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new u0};break;case"SpotLight":$={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new u0};break;case"PointLight":$={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new u0,shadowCameraNear:1,shadowCameraFar:1000};break}return J[Q.id]=$,$}}}var xU=0;function gU(J,Q){return(Q.castShadow?2:0)-(J.castShadow?2:0)+(Q.map?1:0)-(J.map?1:0)}function pU(J){let Q=new bU,$=hU(),Z={version:0,hash:{directionalLength:-1,pointLength:-1,spotLength:-1,rectAreaLength:-1,hemiLength:-1,numDirectionalShadows:-1,numPointShadows:-1,numSpotShadows:-1,numSpotMaps:-1,numLightProbes:-1},ambient:[0,0,0],probe:[],directional:[],directionalShadow:[],directionalShadowMap:[],directionalShadowMatrix:[],spot:[],spotLightMap:[],spotShadow:[],spotShadowMap:[],spotLightMatrix:[],rectArea:[],rectAreaLTC1:null,rectAreaLTC2:null,point:[],pointShadow:[],pointShadowMap:[],pointShadowMatrix:[],hemi:[],numSpotLightShadowsWithMaps:0,numLightProbes:0};for(let U=0;U<9;U++)Z.probe.push(new b);let W=new b,K=new WJ,H=new WJ;function Y(U){let E=0,N=0,G=0;for(let B=0;B<9;B++)Z.probe[B].set(0,0,0);let D=0,M=0,z=0,F=0,q=0,_=0,w=0,V=0,A=0,I=0,P=0;U.sort(gU);for(let B=0,l=U.length;B<l;B++){let C=U[B],m=C.color,o=C.intensity,p=C.distance,n=null;if(C.shadow&&C.shadow.map)if(C.shadow.map.texture.format===p9)n=C.shadow.map.texture;else n=C.shadow.map.depthTexture||C.shadow.map.texture;if(C.isAmbientLight)E+=m.r*o,N+=m.g*o,G+=m.b*o;else if(C.isLightProbe){for(let u=0;u<9;u++)Z.probe[u].addScaledVector(C.sh.coefficients[u],o);P++}else if(C.isDirectionalLight){let u=Q.get(C);if(u.color.copy(C.color).multiplyScalar(C.intensity),C.castShadow){let h=C.shadow,t=$.get(C);t.shadowIntensity=h.intensity,t.shadowBias=h.bias,t.shadowNormalBias=h.normalBias,t.shadowRadius=h.radius,t.shadowMapSize=h.mapSize,Z.directionalShadow[D]=t,Z.directionalShadowMap[D]=n,Z.directionalShadowMatrix[D]=C.shadow.matrix,_++}Z.directional[D]=u,D++}else if(C.isSpotLight){let u=Q.get(C);u.position.setFromMatrixPosition(C.matrixWorld),u.color.copy(m).multiplyScalar(o),u.distance=p,u.coneCos=Math.cos(C.angle),u.penumbraCos=Math.cos(C.angle*(1-C.penumbra)),u.decay=C.decay,Z.spot[z]=u;let h=C.shadow;if(C.map){if(Z.spotLightMap[A]=C.map,A++,h.updateMatrices(C),C.castShadow)I++}if(Z.spotLightMatrix[z]=h.matrix,C.castShadow){let t=$.get(C);t.shadowIntensity=h.intensity,t.shadowBias=h.bias,t.shadowNormalBias=h.normalBias,t.shadowRadius=h.radius,t.shadowMapSize=h.mapSize,Z.spotShadow[z]=t,Z.spotShadowMap[z]=n,V++}z++}else if(C.isRectAreaLight){let u=Q.get(C);u.color.copy(m).multiplyScalar(o),u.halfWidth.set(C.width*0.5,0,0),u.halfHeight.set(0,C.height*0.5,0),Z.rectArea[F]=u,F++}else if(C.isPointLight){let u=Q.get(C);if(u.color.copy(C.color).multiplyScalar(C.intensity),u.distance=C.distance,u.decay=C.decay,C.castShadow){let h=C.shadow,t=$.get(C);t.shadowIntensity=h.intensity,t.shadowBias=h.bias,t.shadowNormalBias=h.normalBias,t.shadowRadius=h.radius,t.shadowMapSize=h.mapSize,t.shadowCameraNear=h.camera.near,t.shadowCameraFar=h.camera.far,Z.pointShadow[M]=t,Z.pointShadowMap[M]=n,Z.pointShadowMatrix[M]=C.shadow.matrix,w++}Z.point[M]=u,M++}else if(C.isHemisphereLight){let u=Q.get(C);u.skyColor.copy(C.color).multiplyScalar(o),u.groundColor.copy(C.groundColor).multiplyScalar(o),Z.hemi[q]=u,q++}}if(F>0)if(J.has("OES_texture_float_linear")===!0)Z.rectAreaLTC1=U0.LTC_FLOAT_1,Z.rectAreaLTC2=U0.LTC_FLOAT_2;else Z.rectAreaLTC1=U0.LTC_HALF_1,Z.rectAreaLTC2=U0.LTC_HALF_2;Z.ambient[0]=E,Z.ambient[1]=N,Z.ambient[2]=G;let O=Z.hash;if(O.directionalLength!==D||O.pointLength!==M||O.spotLength!==z||O.rectAreaLength!==F||O.hemiLength!==q||O.numDirectionalShadows!==_||O.numPointShadows!==w||O.numSpotShadows!==V||O.numSpotMaps!==A||O.numLightProbes!==P)Z.directional.length=D,Z.spot.length=z,Z.rectArea.length=F,Z.point.length=M,Z.hemi.length=q,Z.directionalShadow.length=_,Z.directionalShadowMap.length=_,Z.pointShadow.length=w,Z.pointShadowMap.length=w,Z.spotShadow.length=V,Z.spotShadowMap.length=V,Z.directionalShadowMatrix.length=_,Z.pointShadowMatrix.length=w,Z.spotLightMatrix.length=V+A-I,Z.spotLightMap.length=A,Z.numSpotLightShadowsWithMaps=I,Z.numLightProbes=P,O.directionalLength=D,O.pointLength=M,O.spotLength=z,O.rectAreaLength=F,O.hemiLength=q,O.numDirectionalShadows=_,O.numPointShadows=w,O.numSpotShadows=V,O.numSpotMaps=A,O.numLightProbes=P,Z.version=xU++}function X(U,E){let N=0,G=0,D=0,M=0,z=0,F=E.matrixWorldInverse;for(let q=0,_=U.length;q<_;q++){let w=U[q];if(w.isDirectionalLight){let V=Z.directional[N];V.direction.setFromMatrixPosition(w.matrixWorld),W.setFromMatrixPosition(w.target.matrixWorld),V.direction.sub(W),V.direction.transformDirection(F),N++}else if(w.isSpotLight){let V=Z.spot[D];V.position.setFromMatrixPosition(w.matrixWorld),V.position.applyMatrix4(F),V.direction.setFromMatrixPosition(w.matrixWorld),W.setFromMatrixPosition(w.target.matrixWorld),V.direction.sub(W),V.direction.transformDirection(F),D++}else if(w.isRectAreaLight){let V=Z.rectArea[M];V.position.setFromMatrixPosition(w.matrixWorld),V.position.applyMatrix4(F),H.identity(),K.copy(w.matrixWorld),K.premultiply(F),H.extractRotation(K),V.halfWidth.set(w.width*0.5,0,0),V.halfHeight.set(0,w.height*0.5,0),V.halfWidth.applyMatrix4(H),V.halfHeight.applyMatrix4(H),M++}else if(w.isPointLight){let V=Z.point[G];V.position.setFromMatrixPosition(w.matrixWorld),V.position.applyMatrix4(F),G++}else if(w.isHemisphereLight){let V=Z.hemi[z];V.direction.setFromMatrixPosition(w.matrixWorld),V.direction.transformDirection(F),z++}}}return{setup:Y,setupView:X,state:Z}}function KW(J){let Q=new pU(J),$=[],Z=[],W=[];function K(G){N.camera=G,$.length=0,Z.length=0,W.length=0}function H(G){$.push(G)}function Y(G){Z.push(G)}function X(G){W.push(G)}function U(){Q.setup($)}function E(G){Q.setupView($,G)}let N={lightsArray:$,shadowsArray:Z,lightProbeGridArray:W,camera:null,lights:Q,transmissionRenderTarget:{},textureUnits:0};return{init:K,state:N,setupLights:U,setupLightsView:E,pushLight:H,pushShadow:Y,pushLightProbeGrid:X}}function mU(J){let Q=new WeakMap;function $(W,K=0){let H=Q.get(W),Y;if(H===void 0)Y=new KW(J),Q.set(W,[Y]);else if(K>=H.length)Y=new KW(J),H.push(Y);else Y=H[K];return Y}function Z(){Q=new WeakMap}return{get:$,dispose:Z}}var dU=`void main() {
	gl_Position = vec4( position, 1.0 );
}`,lU=`uniform sampler2D shadow_pass;
uniform vec2 resolution;
uniform float radius;
void main() {
	const float samples = float( VSM_SAMPLES );
	float mean = 0.0;
	float squared_mean = 0.0;
	float uvStride = samples <= 1.0 ? 0.0 : 2.0 / ( samples - 1.0 );
	float uvStart = samples <= 1.0 ? 0.0 : - 1.0;
	for ( float i = 0.0; i < samples; i ++ ) {
		float uvOffset = uvStart + i * uvStride;
		#ifdef HORIZONTAL_PASS
			vec2 distribution = texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( uvOffset, 0.0 ) * radius ) / resolution ).rg;
			mean += distribution.x;
			squared_mean += distribution.y * distribution.y + distribution.x * distribution.x;
		#else
			float depth = texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( 0.0, uvOffset ) * radius ) / resolution ).r;
			mean += depth;
			squared_mean += depth * depth;
		#endif
	}
	mean = mean / samples;
	squared_mean = squared_mean / samples;
	float std_dev = sqrt( max( 0.0, squared_mean - mean * mean ) );
	gl_FragColor = vec4( mean, std_dev, 0.0, 1.0 );
}`,uU=[new b(1,0,0),new b(-1,0,0),new b(0,1,0),new b(0,-1,0),new b(0,0,1),new b(0,0,-1)],cU=[new b(0,-1,0),new b(0,-1,0),new b(0,0,1),new b(0,0,-1),new b(0,-1,0),new b(0,-1,0)],HW=new WJ,h8=new b,nQ=new b;function nU(J,Q,$){let Z=new T6,W=new u0,K=new u0,H=new KJ,Y=new BQ,X=new zQ,U={},E=$.maxTextureSize,N={[N8]:CJ,[CJ]:N8,[rJ]:rJ},G=new gJ({defines:{VSM_SAMPLES:8},uniforms:{shadow_pass:{value:null},resolution:{value:new u0},radius:{value:4}},vertexShader:dU,fragmentShader:lU}),D=G.clone();D.defines.HORIZONTAL_PASS=1;let M=new jJ;M.setAttribute("position",new wJ(new Float32Array([-1,-1,0.5,3,-1,0.5,-1,3,0.5]),3));let z=new sJ(M,G),F=this;this.enabled=!1,this.autoUpdate=!0,this.needsUpdate=!1,this.type=w8;let q=this.type;this.render=function(I,P,O){if(F.enabled===!1)return;if(F.autoUpdate===!1&&F.needsUpdate===!1)return;if(I.length===0)return;if(this.type===b$)C0("WebGLShadowMap: PCFSoftShadowMap has been deprecated. Using PCFShadowMap instead."),this.type=w8;let B=J.getRenderTarget(),l=J.getActiveCubeFace(),C=J.getActiveMipmapLevel(),m=J.state;if(m.setBlending(tJ),m.buffers.depth.getReversed()===!0)m.buffers.color.setClear(0,0,0,0);else m.buffers.color.setClear(1,1,1,1);m.buffers.depth.setTest(!0),m.setScissorTest(!1);let o=q!==this.type;if(o)P.traverse(function(p){if(p.material)if(Array.isArray(p.material))p.material.forEach((n)=>n.needsUpdate=!0);else p.material.needsUpdate=!0});for(let p=0,n=I.length;p<n;p++){let u=I[p],h=u.shadow;if(h===void 0){C0("WebGLShadowMap:",u,"has no shadow.");continue}if(h.autoUpdate===!1&&h.needsUpdate===!1)continue;W.copy(h.mapSize);let t=h.getFrameExtents();if(W.multiply(t),K.copy(h.mapSize),W.x>E||W.y>E){if(W.x>E)K.x=Math.floor(E/t.x),W.x=K.x*t.x,h.mapSize.x=K.x;if(W.y>E)K.y=Math.floor(E/t.y),W.y=K.y*t.y,h.mapSize.y=K.y}let e=J.state.buffers.depth.getReversed();if(h.camera._reversedDepth=e,h.map===null||o===!0){if(h.map!==null){if(h.map.depthTexture!==null)h.map.depthTexture.dispose(),h.map.depthTexture=null;h.map.dispose()}if(this.type===E8){if(u.isPointLight){C0("WebGLShadowMap: VSM shadow maps are not supported for PointLights. Use PCF or BasicShadowMap instead.");continue}h.map=new xJ(W.x,W.y,{format:p9,type:E9,minFilter:_J,magFilter:_J,generateMipmaps:!1}),h.map.texture.name=u.name+".shadowMap",h.map.depthTexture=new _9(W.x,W.y,G9),h.map.depthTexture.name=u.name+".shadowMapDepth",h.map.depthTexture.format=x9,h.map.depthTexture.compareFunction=null,h.map.depthTexture.minFilter=w9,h.map.depthTexture.magFilter=w9}else{if(u.isPointLight)h.map=new aQ(W.x),h.map.depthTexture=new MQ(W.x,C9);else h.map=new xJ(W.x,W.y),h.map.depthTexture=new _9(W.x,W.y,C9);if(h.map.depthTexture.name=u.name+".shadowMap",h.map.depthTexture.format=x9,this.type===w8)h.map.depthTexture.compareFunction=e?B6:V6,h.map.depthTexture.minFilter=_J,h.map.depthTexture.magFilter=_J;else h.map.depthTexture.compareFunction=null,h.map.depthTexture.minFilter=w9,h.map.depthTexture.magFilter=w9}h.camera.updateProjectionMatrix()}let H0=h.map.isWebGLCubeRenderTarget?6:1;for(let M0=0;M0<H0;M0++){if(h.map.isWebGLCubeRenderTarget)J.setRenderTarget(h.map,M0),J.clear();else{if(M0===0)J.setRenderTarget(h.map),J.clear();let k0=h.getViewport(M0);H.set(K.x*k0.x,K.y*k0.y,K.x*k0.z,K.y*k0.w),m.viewport(H)}if(u.isPointLight){let{camera:k0,matrix:ZJ}=h,i0=u.distance||k0.far;if(i0!==k0.far)k0.far=i0,k0.updateProjectionMatrix();h8.setFromMatrixPosition(u.matrixWorld),k0.position.copy(h8),nQ.copy(k0.position),nQ.add(uU[M0]),k0.up.copy(cU[M0]),k0.lookAt(nQ),k0.updateMatrixWorld(),ZJ.makeTranslation(-h8.x,-h8.y,-h8.z),HW.multiplyMatrices(k0.projectionMatrix,k0.matrixWorldInverse),h._frustum.setFromProjectionMatrix(HW,k0.coordinateSystem,k0.reversedDepth)}else h.updateMatrices(u);Z=h.getFrustum(),V(P,O,h.camera,u,this.type)}if(h.isPointLightShadow!==!0&&this.type===E8)_(h,O);h.needsUpdate=!1}q=this.type,F.needsUpdate=!1,J.setRenderTarget(B,l,C)};function _(I,P){let O=Q.update(z);if(G.defines.VSM_SAMPLES!==I.blurSamples)G.defines.VSM_SAMPLES=I.blurSamples,D.defines.VSM_SAMPLES=I.blurSamples,G.needsUpdate=!0,D.needsUpdate=!0;if(I.mapPass===null)I.mapPass=new xJ(W.x,W.y,{format:p9,type:E9});G.uniforms.shadow_pass.value=I.map.depthTexture,G.uniforms.resolution.value=I.mapSize,G.uniforms.radius.value=I.radius,J.setRenderTarget(I.mapPass),J.clear(),J.renderBufferDirect(P,null,O,G,z,null),D.uniforms.shadow_pass.value=I.mapPass.texture,D.uniforms.resolution.value=I.mapSize,D.uniforms.radius.value=I.radius,J.setRenderTarget(I.map),J.clear(),J.renderBufferDirect(P,null,O,D,z,null)}function w(I,P,O,B){let l=null,C=O.isPointLight===!0?I.customDistanceMaterial:I.customDepthMaterial;if(C!==void 0)l=C;else if(l=O.isPointLight===!0?X:Y,J.localClippingEnabled&&P.clipShadows===!0&&Array.isArray(P.clippingPlanes)&&P.clippingPlanes.length!==0||P.displacementMap&&P.displacementScale!==0||P.alphaMap&&P.alphaTest>0||P.map&&P.alphaTest>0||P.alphaToCoverage===!0){let m=l.uuid,o=P.uuid,p=U[m];if(p===void 0)p={},U[m]=p;let n=p[o];if(n===void 0)n=l.clone(),p[o]=n,P.addEventListener("dispose",A);l=n}if(l.visible=P.visible,l.wireframe=P.wireframe,B===E8)l.side=P.shadowSide!==null?P.shadowSide:P.side;else l.side=P.shadowSide!==null?P.shadowSide:N[P.side];if(l.alphaMap=P.alphaMap,l.alphaTest=P.alphaToCoverage===!0?0.5:P.alphaTest,l.map=P.map,l.clipShadows=P.clipShadows,l.clippingPlanes=P.clippingPlanes,l.clipIntersection=P.clipIntersection,l.displacementMap=P.displacementMap,l.displacementScale=P.displacementScale,l.displacementBias=P.displacementBias,l.wireframeLinewidth=P.wireframeLinewidth,l.linewidth=P.linewidth,O.isPointLight===!0&&l.isMeshDistanceMaterial===!0){let m=J.properties.get(l);m.light=O}return l}function V(I,P,O,B,l){if(I.visible===!1)return;if(I.layers.test(P.layers)&&(I.isMesh||I.isLine||I.isPoints)){if((I.castShadow||I.receiveShadow&&l===E8)&&(!I.frustumCulled||Z.intersectsObject(I))){I.modelViewMatrix.multiplyMatrices(O.matrixWorldInverse,I.matrixWorld);let o=Q.update(I),p=I.material;if(Array.isArray(p)){let n=o.groups;for(let u=0,h=n.length;u<h;u++){let t=n[u],e=p[t.materialIndex];if(e&&e.visible){let H0=w(I,e,B,l);I.onBeforeShadow(J,I,P,O,o,H0,t),J.renderBufferDirect(O,null,o,H0,I,t),I.onAfterShadow(J,I,P,O,o,H0,t)}}}else if(p.visible){let n=w(I,p,B,l);I.onBeforeShadow(J,I,P,O,o,n,null),J.renderBufferDirect(O,null,o,n,I,null),I.onAfterShadow(J,I,P,O,o,n,null)}}}let m=I.children;for(let o=0,p=m.length;o<p;o++)V(m[o],P,O,B,l)}function A(I){I.target.removeEventListener("dispose",A);for(let O in U){let B=U[O],l=I.target.uuid;if(l in B)B[l].dispose(),delete B[l]}}}function sU(J,Q){function $(){let S=!1,$0=new KJ,c=null,W0=new KJ(0,0,0,0);return{setMask:function(q0){if(c!==q0&&!S)J.colorMask(q0,q0,q0,q0),c=q0},setLocked:function(q0){S=q0},setClear:function(q0,a,K0,T0,HJ){if(HJ===!0)q0*=T0,a*=T0,K0*=T0;if($0.set(q0,a,K0,T0),W0.equals($0)===!1)J.clearColor(q0,a,K0,T0),W0.copy($0)},reset:function(){S=!1,c=null,W0.set(-1,0,0,0)}}}function Z(){let S=!1,$0=!1,c=null,W0=null,q0=null;return{setReversed:function(a){if($0!==a){let K0=Q.get("EXT_clip_control");if(a)K0.clipControlEXT(K0.LOWER_LEFT_EXT,K0.ZERO_TO_ONE_EXT);else K0.clipControlEXT(K0.LOWER_LEFT_EXT,K0.NEGATIVE_ONE_TO_ONE_EXT);$0=a;let T0=q0;q0=null,this.setClear(T0)}},getReversed:function(){return $0},setTest:function(a){if(a)D0(J.DEPTH_TEST);else w0(J.DEPTH_TEST)},setMask:function(a){if(c!==a&&!S)J.depthMask(a),c=a},setFunc:function(a){if($0)a=fZ[a];if(W0!==a){switch(a){case ZZ:J.depthFunc(J.NEVER);break;case WZ:J.depthFunc(J.ALWAYS);break;case KZ:J.depthFunc(J.LESS);break;case M7:J.depthFunc(J.LEQUAL);break;case HZ:J.depthFunc(J.EQUAL);break;case YZ:J.depthFunc(J.GEQUAL);break;case XZ:J.depthFunc(J.GREATER);break;case UZ:J.depthFunc(J.NOTEQUAL);break;default:J.depthFunc(J.LEQUAL)}W0=a}},setLocked:function(a){S=a},setClear:function(a){if(q0!==a){if(q0=a,$0)a=1-a;J.clearDepth(a)}},reset:function(){S=!1,c=null,W0=null,q0=null,$0=!1}}}function W(){let S=!1,$0=null,c=null,W0=null,q0=null,a=null,K0=null,T0=null,HJ=null;return{setTest:function(e0){if(!S)if(e0)D0(J.STENCIL_TEST);else w0(J.STENCIL_TEST)},setMask:function(e0){if($0!==e0&&!S)J.stencilMask(e0),$0=e0},setFunc:function(e0,iJ,$9){if(c!==e0||W0!==iJ||q0!==$9)J.stencilFunc(e0,iJ,$9),c=e0,W0=iJ,q0=$9},setOp:function(e0,iJ,$9){if(a!==e0||K0!==iJ||T0!==$9)J.stencilOp(e0,iJ,$9),a=e0,K0=iJ,T0=$9},setLocked:function(e0){S=e0},setClear:function(e0){if(HJ!==e0)J.clearStencil(e0),HJ=e0},reset:function(){S=!1,$0=null,c=null,W0=null,q0=null,a=null,K0=null,T0=null,HJ=null}}}let K=new $,H=new Z,Y=new W,X=new WeakMap,U=new WeakMap,E={},N={},G={},D=new WeakMap,M=[],z=null,F=!1,q=null,_=null,w=null,V=null,A=null,I=null,P=null,O=new g0(0,0,0),B=0,l=!1,C=null,m=null,o=null,p=null,n=null,u=J.getParameter(J.MAX_COMBINED_TEXTURE_IMAGE_UNITS),h=!1,t=0,e=J.getParameter(J.VERSION);if(e.indexOf("WebGL")!==-1)t=parseFloat(/^WebGL (\d)/.exec(e)[1]),h=t>=1;else if(e.indexOf("OpenGL ES")!==-1)t=parseFloat(/^OpenGL ES (\d)/.exec(e)[1]),h=t>=2;let H0=null,M0={},k0=J.getParameter(J.SCISSOR_BOX),ZJ=J.getParameter(J.VIEWPORT),i0=new KJ().fromArray(k0),i=new KJ().fromArray(ZJ);function Z0(S,$0,c,W0){let q0=new Uint8Array(4),a=J.createTexture();J.bindTexture(S,a),J.texParameteri(S,J.TEXTURE_MIN_FILTER,J.NEAREST),J.texParameteri(S,J.TEXTURE_MAG_FILTER,J.NEAREST);for(let K0=0;K0<c;K0++)if(S===J.TEXTURE_3D||S===J.TEXTURE_2D_ARRAY)J.texImage3D($0,0,J.RGBA,1,1,W0,0,J.RGBA,J.UNSIGNED_BYTE,q0);else J.texImage2D($0+K0,0,J.RGBA,1,1,0,J.RGBA,J.UNSIGNED_BYTE,q0);return a}let F0={};F0[J.TEXTURE_2D]=Z0(J.TEXTURE_2D,J.TEXTURE_2D,1),F0[J.TEXTURE_CUBE_MAP]=Z0(J.TEXTURE_CUBE_MAP,J.TEXTURE_CUBE_MAP_POSITIVE_X,6),F0[J.TEXTURE_2D_ARRAY]=Z0(J.TEXTURE_2D_ARRAY,J.TEXTURE_2D_ARRAY,1,1),F0[J.TEXTURE_3D]=Z0(J.TEXTURE_3D,J.TEXTURE_3D,1,1),K.setClear(0,0,0,1),H.setClear(1),Y.setClear(0),D0(J.DEPTH_TEST),H.setFunc(M7),yJ(!1),QJ(D7),D0(J.CULL_FACE),b0(tJ);function D0(S){if(E[S]!==!0)J.enable(S),E[S]=!0}function w0(S){if(E[S]!==!1)J.disable(S),E[S]=!1}function p0(S,$0){if(G[S]!==$0){if(J.bindFramebuffer(S,$0),G[S]=$0,S===J.DRAW_FRAMEBUFFER)G[J.FRAMEBUFFER]=$0;if(S===J.FRAMEBUFFER)G[J.DRAW_FRAMEBUFFER]=$0;return!0}return!1}function f0(S,$0){let c=M,W0=!1;if(S){if(c=D.get($0),c===void 0)c=[],D.set($0,c);let q0=S.textures;if(c.length!==q0.length||c[0]!==J.COLOR_ATTACHMENT0){for(let a=0,K0=q0.length;a<K0;a++)c[a]=J.COLOR_ATTACHMENT0+a;c.length=q0.length,W0=!0}}else if(c[0]!==J.BACK)c[0]=J.BACK,W0=!0;if(W0)J.drawBuffers(c)}function v0(S){if(z!==S)return J.useProgram(S),z=S,!0;return!1}let t0={[q8]:J.FUNC_ADD,[x$]:J.FUNC_SUBTRACT,[g$]:J.FUNC_REVERSE_SUBTRACT};t0[p$]=J.MIN,t0[m$]=J.MAX;let m0={[d$]:J.ZERO,[l$]:J.ONE,[u$]:J.SRC_COLOR,[n$]:J.SRC_ALPHA,[t$]:J.SRC_ALPHA_SATURATE,[a$]:J.DST_COLOR,[i$]:J.DST_ALPHA,[c$]:J.ONE_MINUS_SRC_COLOR,[s$]:J.ONE_MINUS_SRC_ALPHA,[r$]:J.ONE_MINUS_DST_COLOR,[o$]:J.ONE_MINUS_DST_ALPHA,[e$]:J.CONSTANT_COLOR,[JZ]:J.ONE_MINUS_CONSTANT_COLOR,[QZ]:J.CONSTANT_ALPHA,[$Z]:J.ONE_MINUS_CONSTANT_ALPHA};function b0(S,$0,c,W0,q0,a,K0,T0,HJ,e0){if(S===tJ){if(F===!0)w0(J.BLEND),F=!1;return}if(F===!1)D0(J.BLEND),F=!0;if(S!==h$){if(S!==q||e0!==l){if(_!==q8||A!==q8)J.blendEquation(J.FUNC_ADD),_=q8,A=q8;if(e0)switch(S){case C8:J.blendFuncSeparate(J.ONE,J.ONE_MINUS_SRC_ALPHA,J.ONE,J.ONE_MINUS_SRC_ALPHA);break;case R7:J.blendFunc(J.ONE,J.ONE);break;case O7:J.blendFuncSeparate(J.ZERO,J.ONE_MINUS_SRC_COLOR,J.ZERO,J.ONE);break;case k7:J.blendFuncSeparate(J.DST_COLOR,J.ONE_MINUS_SRC_ALPHA,J.ZERO,J.ONE);break;default:_0("WebGLState: Invalid blending: ",S);break}else switch(S){case C8:J.blendFuncSeparate(J.SRC_ALPHA,J.ONE_MINUS_SRC_ALPHA,J.ONE,J.ONE_MINUS_SRC_ALPHA);break;case R7:J.blendFuncSeparate(J.SRC_ALPHA,J.ONE,J.ONE,J.ONE);break;case O7:_0("WebGLState: SubtractiveBlending requires material.premultipliedAlpha = true");break;case k7:_0("WebGLState: MultiplyBlending requires material.premultipliedAlpha = true");break;default:_0("WebGLState: Invalid blending: ",S);break}w=null,V=null,I=null,P=null,O.set(0,0,0),B=0,q=S,l=e0}return}if(q0=q0||$0,a=a||c,K0=K0||W0,$0!==_||q0!==A)J.blendEquationSeparate(t0[$0],t0[q0]),_=$0,A=q0;if(c!==w||W0!==V||a!==I||K0!==P)J.blendFuncSeparate(m0[c],m0[W0],m0[a],m0[K0]),w=c,V=W0,I=a,P=K0;if(T0.equals(O)===!1||HJ!==B)J.blendColor(T0.r,T0.g,T0.b,HJ),O.copy(T0),B=HJ;q=S,l=!1}function FJ(S,$0){S.side===rJ?w0(J.CULL_FACE):D0(J.CULL_FACE);let c=S.side===CJ;if($0)c=!c;yJ(c),S.blending===C8&&S.transparent===!1?b0(tJ):b0(S.blending,S.blendEquation,S.blendSrc,S.blendDst,S.blendEquationAlpha,S.blendSrcAlpha,S.blendDstAlpha,S.blendColor,S.blendAlpha,S.premultipliedAlpha),H.setFunc(S.depthFunc),H.setTest(S.depthTest),H.setMask(S.depthWrite),K.setMask(S.colorWrite);let W0=S.stencilWrite;if(Y.setTest(W0),W0)Y.setMask(S.stencilWriteMask),Y.setFunc(S.stencilFunc,S.stencilRef,S.stencilFuncMask),Y.setOp(S.stencilFail,S.stencilZFail,S.stencilZPass);DJ(S.polygonOffset,S.polygonOffsetFactor,S.polygonOffsetUnits),S.alphaToCoverage===!0?D0(J.SAMPLE_ALPHA_TO_COVERAGE):w0(J.SAMPLE_ALPHA_TO_COVERAGE)}function yJ(S){if(C!==S){if(S)J.frontFace(J.CW);else J.frontFace(J.CCW);C=S}}function QJ(S){if(S!==f$){if(D0(J.CULL_FACE),S!==m)if(S===D7)J.cullFace(J.BACK);else if(S===v$)J.cullFace(J.FRONT);else J.cullFace(J.FRONT_AND_BACK)}else w0(J.CULL_FACE);m=S}function OJ(S){if(S!==o){if(h)J.lineWidth(S);o=S}}function DJ(S,$0,c){if(S){if(D0(J.POLYGON_OFFSET_FILL),p!==$0||n!==c){if(p=$0,n=c,H.getReversed())$0=-$0;J.polygonOffset($0,c)}}else w0(J.POLYGON_OFFSET_FILL)}function EJ(S){if(S)D0(J.SCISSOR_TEST);else w0(J.SCISSOR_TEST)}function j(S){if(S===void 0)S=J.TEXTURE0+u-1;if(H0!==S)J.activeTexture(S),H0=S}function fJ(S,$0,c){if(c===void 0)if(H0===null)c=J.TEXTURE0+u-1;else c=H0;let W0=M0[c];if(W0===void 0)W0={type:void 0,texture:void 0},M0[c]=W0;if(W0.type!==S||W0.texture!==$0){if(H0!==c)J.activeTexture(c),H0=c;J.bindTexture(S,$0||F0[S]),W0.type=S,W0.texture=$0}}function c0(){let S=M0[H0];if(S!==void 0&&S.type!==void 0)J.bindTexture(S.type,null),S.type=void 0,S.texture=void 0}function $J(){try{J.compressedTexImage2D(...arguments)}catch(S){_0("WebGLState:",S)}}function L(){try{J.compressedTexImage3D(...arguments)}catch(S){_0("WebGLState:",S)}}function R(){try{J.texSubImage2D(...arguments)}catch(S){_0("WebGLState:",S)}}function T(){try{J.texSubImage3D(...arguments)}catch(S){_0("WebGLState:",S)}}function g(){try{J.compressedTexSubImage2D(...arguments)}catch(S){_0("WebGLState:",S)}}function r(){try{J.compressedTexSubImage3D(...arguments)}catch(S){_0("WebGLState:",S)}}function J0(){try{J.texStorage2D(...arguments)}catch(S){_0("WebGLState:",S)}}function Y0(){try{J.texStorage3D(...arguments)}catch(S){_0("WebGLState:",S)}}function d(){try{J.texImage2D(...arguments)}catch(S){_0("WebGLState:",S)}}function s(){try{J.texImage3D(...arguments)}catch(S){_0("WebGLState:",S)}}function N0(S){if(N[S]!==void 0)return N[S];else return J.getParameter(S)}function V0(S,$0){if(N[S]!==$0)J.pixelStorei(S,$0),N[S]=$0}function X0(S){if(i0.equals(S)===!1)J.scissor(S.x,S.y,S.z,S.w),i0.copy(S)}function Q0(S){if(i.equals(S)===!1)J.viewport(S.x,S.y,S.z,S.w),i.copy(S)}function I0(S,$0){let c=U.get($0);if(c===void 0)c=new WeakMap,U.set($0,c);let W0=c.get(S);if(W0===void 0)W0=J.getUniformBlockIndex($0,S.name),c.set(S,W0)}function A0(S,$0){let W0=U.get($0).get(S);if(X.get($0)!==W0)J.uniformBlockBinding($0,W0,S.__bindingPointIndex),X.set($0,W0)}function l0(){J.disable(J.BLEND),J.disable(J.CULL_FACE),J.disable(J.DEPTH_TEST),J.disable(J.POLYGON_OFFSET_FILL),J.disable(J.SCISSOR_TEST),J.disable(J.STENCIL_TEST),J.disable(J.SAMPLE_ALPHA_TO_COVERAGE),J.blendEquation(J.FUNC_ADD),J.blendFunc(J.ONE,J.ZERO),J.blendFuncSeparate(J.ONE,J.ZERO,J.ONE,J.ZERO),J.blendColor(0,0,0,0),J.colorMask(!0,!0,!0,!0),J.clearColor(0,0,0,0),J.depthMask(!0),J.depthFunc(J.LESS),H.setReversed(!1),J.clearDepth(1),J.stencilMask(4294967295),J.stencilFunc(J.ALWAYS,0,4294967295),J.stencilOp(J.KEEP,J.KEEP,J.KEEP),J.clearStencil(0),J.cullFace(J.BACK),J.frontFace(J.CCW),J.polygonOffset(0,0),J.activeTexture(J.TEXTURE0),J.bindFramebuffer(J.FRAMEBUFFER,null),J.bindFramebuffer(J.DRAW_FRAMEBUFFER,null),J.bindFramebuffer(J.READ_FRAMEBUFFER,null),J.useProgram(null),J.lineWidth(1),J.scissor(0,0,J.canvas.width,J.canvas.height),J.viewport(0,0,J.canvas.width,J.canvas.height),J.pixelStorei(J.PACK_ALIGNMENT,4),J.pixelStorei(J.UNPACK_ALIGNMENT,4),J.pixelStorei(J.UNPACK_FLIP_Y_WEBGL,!1),J.pixelStorei(J.UNPACK_PREMULTIPLY_ALPHA_WEBGL,!1),J.pixelStorei(J.UNPACK_COLORSPACE_CONVERSION_WEBGL,J.BROWSER_DEFAULT_WEBGL),J.pixelStorei(J.PACK_ROW_LENGTH,0),J.pixelStorei(J.PACK_SKIP_PIXELS,0),J.pixelStorei(J.PACK_SKIP_ROWS,0),J.pixelStorei(J.UNPACK_ROW_LENGTH,0),J.pixelStorei(J.UNPACK_IMAGE_HEIGHT,0),J.pixelStorei(J.UNPACK_SKIP_PIXELS,0),J.pixelStorei(J.UNPACK_SKIP_ROWS,0),J.pixelStorei(J.UNPACK_SKIP_IMAGES,0),E={},N={},H0=null,M0={},G={},D=new WeakMap,M=[],z=null,F=!1,q=null,_=null,w=null,V=null,A=null,I=null,P=null,O=new g0(0,0,0),B=0,l=!1,C=null,m=null,o=null,p=null,n=null,i0.set(0,0,J.canvas.width,J.canvas.height),i.set(0,0,J.canvas.width,J.canvas.height),K.reset(),H.reset(),Y.reset()}return{buffers:{color:K,depth:H,stencil:Y},enable:D0,disable:w0,bindFramebuffer:p0,drawBuffers:f0,useProgram:v0,setBlending:b0,setMaterial:FJ,setFlipSided:yJ,setCullFace:QJ,setLineWidth:OJ,setPolygonOffset:DJ,setScissorTest:EJ,activeTexture:j,bindTexture:fJ,unbindTexture:c0,compressedTexImage2D:$J,compressedTexImage3D:L,texImage2D:d,texImage3D:s,pixelStorei:V0,getParameter:N0,updateUBOMapping:I0,uniformBlockBinding:A0,texStorage2D:J0,texStorage3D:Y0,texSubImage2D:R,texSubImage3D:T,compressedTexSubImage2D:g,compressedTexSubImage3D:r,scissor:X0,viewport:Q0,reset:l0}}function iU(J,Q,$,Z,W,K,H){let Y=Q.has("WEBGL_multisampled_render_to_texture")?Q.get("WEBGL_multisampled_render_to_texture"):null,X=typeof navigator>"u"?!1:/OculusBrowser/g.test(navigator.userAgent),U=new u0,E=new WeakMap,N=new Set,G,D=new WeakMap,M=!1;try{M=typeof OffscreenCanvas<"u"&&new OffscreenCanvas(1,1).getContext("2d")!==null}catch(L){}function z(L,R){return M?new OffscreenCanvas(L,R):A8("canvas")}function F(L,R,T){let g=1,r=$J(L);if(r.width>T||r.height>T)g=T/Math.max(r.width,r.height);if(g<1)if(typeof HTMLImageElement<"u"&&L instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&L instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&L instanceof ImageBitmap||typeof VideoFrame<"u"&&L instanceof VideoFrame){let J0=Math.floor(g*r.width),Y0=Math.floor(g*r.height);if(G===void 0)G=z(J0,Y0);let d=R?z(J0,Y0):G;return d.width=J0,d.height=Y0,d.getContext("2d").drawImage(L,0,0,J0,Y0),C0("WebGLRenderer: Texture has been resized from ("+r.width+"x"+r.height+") to ("+J0+"x"+Y0+")."),d}else{if("data"in L)C0("WebGLRenderer: Image in DataTexture is too big ("+r.width+"x"+r.height+").");return L}return L}function q(L){return L.generateMipmaps}function _(L){J.generateMipmap(L)}function w(L){if(L.isWebGLCubeRenderTarget)return J.TEXTURE_CUBE_MAP;if(L.isWebGL3DRenderTarget)return J.TEXTURE_3D;if(L.isWebGLArrayRenderTarget||L.isCompressedArrayTexture)return J.TEXTURE_2D_ARRAY;return J.TEXTURE_2D}function V(L,R,T,g,r,J0=!1){if(L!==null){if(J[L]!==void 0)return J[L];C0("WebGLRenderer: Attempt to use non-existing WebGL internal format '"+L+"'")}let Y0;if(g){if(Y0=Q.get("EXT_texture_norm16"),!Y0)C0("WebGLRenderer: Unable to use normalized textures without EXT_texture_norm16 extension")}let d=R;if(R===J.RED){if(T===J.FLOAT)d=J.R32F;if(T===J.HALF_FLOAT)d=J.R16F;if(T===J.UNSIGNED_BYTE)d=J.R8;if(T===J.UNSIGNED_SHORT&&Y0)d=Y0.R16_EXT;if(T===J.SHORT&&Y0)d=Y0.R16_SNORM_EXT}if(R===J.RED_INTEGER){if(T===J.UNSIGNED_BYTE)d=J.R8UI;if(T===J.UNSIGNED_SHORT)d=J.R16UI;if(T===J.UNSIGNED_INT)d=J.R32UI;if(T===J.BYTE)d=J.R8I;if(T===J.SHORT)d=J.R16I;if(T===J.INT)d=J.R32I}if(R===J.RG){if(T===J.FLOAT)d=J.RG32F;if(T===J.HALF_FLOAT)d=J.RG16F;if(T===J.UNSIGNED_BYTE)d=J.RG8;if(T===J.UNSIGNED_SHORT&&Y0)d=Y0.RG16_EXT;if(T===J.SHORT&&Y0)d=Y0.RG16_SNORM_EXT}if(R===J.RG_INTEGER){if(T===J.UNSIGNED_BYTE)d=J.RG8UI;if(T===J.UNSIGNED_SHORT)d=J.RG16UI;if(T===J.UNSIGNED_INT)d=J.RG32UI;if(T===J.BYTE)d=J.RG8I;if(T===J.SHORT)d=J.RG16I;if(T===J.INT)d=J.RG32I}if(R===J.RGB_INTEGER){if(T===J.UNSIGNED_BYTE)d=J.RGB8UI;if(T===J.UNSIGNED_SHORT)d=J.RGB16UI;if(T===J.UNSIGNED_INT)d=J.RGB32UI;if(T===J.BYTE)d=J.RGB8I;if(T===J.SHORT)d=J.RGB16I;if(T===J.INT)d=J.RGB32I}if(R===J.RGBA_INTEGER){if(T===J.UNSIGNED_BYTE)d=J.RGBA8UI;if(T===J.UNSIGNED_SHORT)d=J.RGBA16UI;if(T===J.UNSIGNED_INT)d=J.RGBA32UI;if(T===J.BYTE)d=J.RGBA8I;if(T===J.SHORT)d=J.RGBA16I;if(T===J.INT)d=J.RGBA32I}if(R===J.RGB){if(T===J.UNSIGNED_SHORT&&Y0)d=Y0.RGB16_EXT;if(T===J.SHORT&&Y0)d=Y0.RGB16_SNORM_EXT;if(T===J.UNSIGNED_INT_5_9_9_9_REV)d=J.RGB9_E5;if(T===J.UNSIGNED_INT_10F_11F_11F_REV)d=J.R11F_G11F_B10F}if(R===J.RGBA){let s=J0?EQ:h0.getTransfer(r);if(T===J.FLOAT)d=J.RGBA32F;if(T===J.HALF_FLOAT)d=J.RGBA16F;if(T===J.UNSIGNED_BYTE)d=s===r0?J.SRGB8_ALPHA8:J.RGBA8;if(T===J.UNSIGNED_SHORT&&Y0)d=Y0.RGBA16_EXT;if(T===J.SHORT&&Y0)d=Y0.RGBA16_SNORM_EXT;if(T===J.UNSIGNED_SHORT_4_4_4_4)d=J.RGBA4;if(T===J.UNSIGNED_SHORT_5_5_5_1)d=J.RGB5_A1}if(d===J.R16F||d===J.R32F||d===J.RG16F||d===J.RG32F||d===J.RGBA16F||d===J.RGBA32F)Q.get("EXT_color_buffer_float");return d}function A(L,R){let T;if(L){if(R===null||R===C9||R===D8)T=J.DEPTH24_STENCIL8;else if(R===G9)T=J.DEPTH32F_STENCIL8;else if(R===T8)T=J.DEPTH24_STENCIL8,C0("DepthTexture: 16 bit depth attachment is not supported with stencil. Using 24-bit attachment.")}else if(R===null||R===C9||R===D8)T=J.DEPTH_COMPONENT24;else if(R===G9)T=J.DEPTH_COMPONENT32F;else if(R===T8)T=J.DEPTH_COMPONENT16;return T}function I(L,R){if(q(L)===!0||L.isFramebufferTexture&&L.minFilter!==w9&&L.minFilter!==_J)return Math.log2(Math.max(R.width,R.height))+1;else if(L.mipmaps!==void 0&&L.mipmaps.length>0)return L.mipmaps.length;else if(L.isCompressedTexture&&Array.isArray(L.image))return R.mipmaps.length;else return 1}function P(L){let R=L.target;if(R.removeEventListener("dispose",P),B(R),R.isVideoTexture)E.delete(R);if(R.isHTMLTexture)N.delete(R)}function O(L){let R=L.target;R.removeEventListener("dispose",O),C(R)}function B(L){let R=Z.get(L);if(R.__webglInit===void 0)return;let T=L.source,g=D.get(T);if(g){let r=g[R.__cacheKey];if(r.usedTimes--,r.usedTimes===0)l(L);if(Object.keys(g).length===0)D.delete(T)}Z.remove(L)}function l(L){let R=Z.get(L);J.deleteTexture(R.__webglTexture);let T=L.source,g=D.get(T);delete g[R.__cacheKey],H.memory.textures--}function C(L){let R=Z.get(L);if(L.depthTexture)L.depthTexture.dispose(),Z.remove(L.depthTexture);if(L.isWebGLCubeRenderTarget)for(let g=0;g<6;g++){if(Array.isArray(R.__webglFramebuffer[g]))for(let r=0;r<R.__webglFramebuffer[g].length;r++)J.deleteFramebuffer(R.__webglFramebuffer[g][r]);else J.deleteFramebuffer(R.__webglFramebuffer[g]);if(R.__webglDepthbuffer)J.deleteRenderbuffer(R.__webglDepthbuffer[g])}else{if(Array.isArray(R.__webglFramebuffer))for(let g=0;g<R.__webglFramebuffer.length;g++)J.deleteFramebuffer(R.__webglFramebuffer[g]);else J.deleteFramebuffer(R.__webglFramebuffer);if(R.__webglDepthbuffer)J.deleteRenderbuffer(R.__webglDepthbuffer);if(R.__webglMultisampledFramebuffer)J.deleteFramebuffer(R.__webglMultisampledFramebuffer);if(R.__webglColorRenderbuffer){for(let g=0;g<R.__webglColorRenderbuffer.length;g++)if(R.__webglColorRenderbuffer[g])J.deleteRenderbuffer(R.__webglColorRenderbuffer[g])}if(R.__webglDepthRenderbuffer)J.deleteRenderbuffer(R.__webglDepthRenderbuffer)}let T=L.textures;for(let g=0,r=T.length;g<r;g++){let J0=Z.get(T[g]);if(J0.__webglTexture)J.deleteTexture(J0.__webglTexture),H.memory.textures--;Z.remove(T[g])}Z.remove(L)}let m=0;function o(){m=0}function p(){return m}function n(L){m=L}function u(){let L=m;if(L>=W.maxTextures)C0("WebGLTextures: Trying to use "+L+" texture units while this GPU supports only "+W.maxTextures);return m+=1,L}function h(L){let R=[];return R.push(L.wrapS),R.push(L.wrapT),R.push(L.wrapR||0),R.push(L.magFilter),R.push(L.minFilter),R.push(L.anisotropy),R.push(L.internalFormat),R.push(L.format),R.push(L.type),R.push(L.generateMipmaps),R.push(L.premultiplyAlpha),R.push(L.flipY),R.push(L.unpackAlignment),R.push(L.colorSpace),R.join()}function t(L,R){let T=Z.get(L);if(L.isVideoTexture)fJ(L);if(L.isRenderTargetTexture===!1&&L.isExternalTexture!==!0&&L.version>0&&T.__version!==L.version){let g=L.image;if(g===null)C0("WebGLRenderer: Texture marked for update but no image data found.");else if(g.complete===!1)C0("WebGLRenderer: Texture marked for update but image is incomplete");else{w0(T,L,R);return}}else if(L.isExternalTexture)T.__webglTexture=L.sourceTexture?L.sourceTexture:null;$.bindTexture(J.TEXTURE_2D,T.__webglTexture,J.TEXTURE0+R)}function e(L,R){let T=Z.get(L);if(L.isRenderTargetTexture===!1&&L.version>0&&T.__version!==L.version){w0(T,L,R);return}else if(L.isExternalTexture)T.__webglTexture=L.sourceTexture?L.sourceTexture:null;$.bindTexture(J.TEXTURE_2D_ARRAY,T.__webglTexture,J.TEXTURE0+R)}function H0(L,R){let T=Z.get(L);if(L.isRenderTargetTexture===!1&&L.version>0&&T.__version!==L.version){w0(T,L,R);return}$.bindTexture(J.TEXTURE_3D,T.__webglTexture,J.TEXTURE0+R)}function M0(L,R){let T=Z.get(L);if(L.isCubeDepthTexture!==!0&&L.version>0&&T.__version!==L.version){p0(T,L,R);return}$.bindTexture(J.TEXTURE_CUBE_MAP,T.__webglTexture,J.TEXTURE0+R)}let k0={[qZ]:J.REPEAT,[q6]:J.CLAMP_TO_EDGE,[FZ]:J.MIRRORED_REPEAT},ZJ={[w9]:J.NEAREST,[DZ]:J.NEAREST_MIPMAP_NEAREST,[P8]:J.NEAREST_MIPMAP_LINEAR,[_J]:J.LINEAR,[F6]:J.LINEAR_MIPMAP_NEAREST,[h9]:J.LINEAR_MIPMAP_LINEAR},i0={[AZ]:J.NEVER,[TZ]:J.ALWAYS,[wZ]:J.LESS,[V6]:J.LEQUAL,[CZ]:J.EQUAL,[B6]:J.GEQUAL,[_Z]:J.GREATER,[PZ]:J.NOTEQUAL};function i(L,R){if(R.type===G9&&Q.has("OES_texture_float_linear")===!1&&(R.magFilter===_J||R.magFilter===F6||R.magFilter===P8||R.magFilter===h9||R.minFilter===_J||R.minFilter===F6||R.minFilter===P8||R.minFilter===h9))C0("WebGLRenderer: Unable to use linear filtering with floating point textures. OES_texture_float_linear not supported on this device.");if(J.texParameteri(L,J.TEXTURE_WRAP_S,k0[R.wrapS]),J.texParameteri(L,J.TEXTURE_WRAP_T,k0[R.wrapT]),L===J.TEXTURE_3D||L===J.TEXTURE_2D_ARRAY)J.texParameteri(L,J.TEXTURE_WRAP_R,k0[R.wrapR]);if(J.texParameteri(L,J.TEXTURE_MAG_FILTER,ZJ[R.magFilter]),J.texParameteri(L,J.TEXTURE_MIN_FILTER,ZJ[R.minFilter]),R.compareFunction)J.texParameteri(L,J.TEXTURE_COMPARE_MODE,J.COMPARE_REF_TO_TEXTURE),J.texParameteri(L,J.TEXTURE_COMPARE_FUNC,i0[R.compareFunction]);if(Q.has("EXT_texture_filter_anisotropic")===!0){if(R.magFilter===w9)return;if(R.minFilter!==P8&&R.minFilter!==h9)return;if(R.type===G9&&Q.has("OES_texture_float_linear")===!1)return;if(R.anisotropy>1||Z.get(R).__currentAnisotropy){let T=Q.get("EXT_texture_filter_anisotropic");J.texParameterf(L,T.TEXTURE_MAX_ANISOTROPY_EXT,Math.min(R.anisotropy,W.getMaxAnisotropy())),Z.get(R).__currentAnisotropy=R.anisotropy}}}function Z0(L,R){let T=!1;if(L.__webglInit===void 0)L.__webglInit=!0,R.addEventListener("dispose",P);let g=R.source,r=D.get(g);if(r===void 0)r={},D.set(g,r);let J0=h(R);if(J0!==L.__cacheKey){if(r[J0]===void 0)r[J0]={texture:J.createTexture(),usedTimes:0},H.memory.textures++,T=!0;r[J0].usedTimes++;let Y0=r[L.__cacheKey];if(Y0!==void 0){if(r[L.__cacheKey].usedTimes--,Y0.usedTimes===0)l(R)}L.__cacheKey=J0,L.__webglTexture=r[J0].texture}return T}function F0(L,R,T){return Math.floor(Math.floor(L/T)/R)}function D0(L,R,T,g){let J0=L.updateRanges;if(J0.length===0)$.texSubImage2D(J.TEXTURE_2D,0,0,0,R.width,R.height,T,g,R.data);else{J0.sort((V0,X0)=>V0.start-X0.start);let Y0=0;for(let V0=1;V0<J0.length;V0++){let X0=J0[Y0],Q0=J0[V0],I0=X0.start+X0.count,A0=F0(Q0.start,R.width,4),l0=F0(X0.start,R.width,4);if(Q0.start<=I0+1&&A0===l0&&F0(Q0.start+Q0.count-1,R.width,4)===A0)X0.count=Math.max(X0.count,Q0.start+Q0.count-X0.start);else++Y0,J0[Y0]=Q0}J0.length=Y0+1;let d=$.getParameter(J.UNPACK_ROW_LENGTH),s=$.getParameter(J.UNPACK_SKIP_PIXELS),N0=$.getParameter(J.UNPACK_SKIP_ROWS);$.pixelStorei(J.UNPACK_ROW_LENGTH,R.width);for(let V0=0,X0=J0.length;V0<X0;V0++){let Q0=J0[V0],I0=Math.floor(Q0.start/4),A0=Math.ceil(Q0.count/4),l0=I0%R.width,S=Math.floor(I0/R.width),$0=A0,c=1;$.pixelStorei(J.UNPACK_SKIP_PIXELS,l0),$.pixelStorei(J.UNPACK_SKIP_ROWS,S),$.texSubImage2D(J.TEXTURE_2D,0,l0,S,$0,1,T,g,R.data)}L.clearUpdateRanges(),$.pixelStorei(J.UNPACK_ROW_LENGTH,d),$.pixelStorei(J.UNPACK_SKIP_PIXELS,s),$.pixelStorei(J.UNPACK_SKIP_ROWS,N0)}}function w0(L,R,T){let g=J.TEXTURE_2D;if(R.isDataArrayTexture||R.isCompressedArrayTexture)g=J.TEXTURE_2D_ARRAY;if(R.isData3DTexture)g=J.TEXTURE_3D;let r=Z0(L,R),J0=R.source;$.bindTexture(g,L.__webglTexture,J.TEXTURE0+T);let Y0=Z.get(J0);if(J0.version!==Y0.__version||r===!0){if($.activeTexture(J.TEXTURE0+T),(typeof ImageBitmap<"u"&&R.image instanceof ImageBitmap)===!1){let c=h0.getPrimaries(h0.workingColorSpace),W0=R.colorSpace===m9?null:h0.getPrimaries(R.colorSpace),q0=R.colorSpace===m9||c===W0?J.NONE:J.BROWSER_DEFAULT_WEBGL;$.pixelStorei(J.UNPACK_FLIP_Y_WEBGL,R.flipY),$.pixelStorei(J.UNPACK_PREMULTIPLY_ALPHA_WEBGL,R.premultiplyAlpha),$.pixelStorei(J.UNPACK_COLORSPACE_CONVERSION_WEBGL,q0)}$.pixelStorei(J.UNPACK_ALIGNMENT,R.unpackAlignment);let s=F(R.image,!1,W.maxTextureSize);s=c0(R,s);let N0=K.convert(R.format,R.colorSpace),V0=K.convert(R.type),X0=V(R.internalFormat,N0,V0,R.normalized,R.colorSpace,R.isVideoTexture);i(g,R);let Q0,I0=R.mipmaps,A0=R.isVideoTexture!==!0,l0=Y0.__version===void 0||r===!0,S=J0.dataReady,$0=I(R,s);if(R.isDepthTexture){if(X0=A(R.format===g9,R.type),l0)if(A0)$.texStorage2D(J.TEXTURE_2D,1,X0,s.width,s.height);else $.texImage2D(J.TEXTURE_2D,0,X0,s.width,s.height,0,N0,V0,null)}else if(R.isDataTexture)if(I0.length>0){if(A0&&l0)$.texStorage2D(J.TEXTURE_2D,$0,X0,I0[0].width,I0[0].height);for(let c=0,W0=I0.length;c<W0;c++)if(Q0=I0[c],A0){if(S)$.texSubImage2D(J.TEXTURE_2D,c,0,0,Q0.width,Q0.height,N0,V0,Q0.data)}else $.texImage2D(J.TEXTURE_2D,c,X0,Q0.width,Q0.height,0,N0,V0,Q0.data);R.generateMipmaps=!1}else if(A0){if(l0)$.texStorage2D(J.TEXTURE_2D,$0,X0,s.width,s.height);if(S)D0(R,s,N0,V0)}else $.texImage2D(J.TEXTURE_2D,0,X0,s.width,s.height,0,N0,V0,s.data);else if(R.isCompressedTexture)if(R.isCompressedArrayTexture){if(A0&&l0)$.texStorage3D(J.TEXTURE_2D_ARRAY,$0,X0,I0[0].width,I0[0].height,s.depth);for(let c=0,W0=I0.length;c<W0;c++)if(Q0=I0[c],R.format!==eJ)if(N0!==null)if(A0){if(S)if(R.layerUpdates.size>0){let q0=pQ(Q0.width,Q0.height,R.format,R.type);for(let a of R.layerUpdates){let K0=Q0.data.subarray(a*q0/Q0.data.BYTES_PER_ELEMENT,(a+1)*q0/Q0.data.BYTES_PER_ELEMENT);$.compressedTexSubImage3D(J.TEXTURE_2D_ARRAY,c,0,0,a,Q0.width,Q0.height,1,N0,K0)}R.clearLayerUpdates()}else $.compressedTexSubImage3D(J.TEXTURE_2D_ARRAY,c,0,0,0,Q0.width,Q0.height,s.depth,N0,Q0.data)}else $.compressedTexImage3D(J.TEXTURE_2D_ARRAY,c,X0,Q0.width,Q0.height,s.depth,0,Q0.data,0,0);else C0("WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()");else if(A0){if(S)$.texSubImage3D(J.TEXTURE_2D_ARRAY,c,0,0,0,Q0.width,Q0.height,s.depth,N0,V0,Q0.data)}else $.texImage3D(J.TEXTURE_2D_ARRAY,c,X0,Q0.width,Q0.height,s.depth,0,N0,V0,Q0.data)}else{if(A0&&l0)$.texStorage2D(J.TEXTURE_2D,$0,X0,I0[0].width,I0[0].height);for(let c=0,W0=I0.length;c<W0;c++)if(Q0=I0[c],R.format!==eJ)if(N0!==null)if(A0){if(S)$.compressedTexSubImage2D(J.TEXTURE_2D,c,0,0,Q0.width,Q0.height,N0,Q0.data)}else $.compressedTexImage2D(J.TEXTURE_2D,c,X0,Q0.width,Q0.height,0,Q0.data);else C0("WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()");else if(A0){if(S)$.texSubImage2D(J.TEXTURE_2D,c,0,0,Q0.width,Q0.height,N0,V0,Q0.data)}else $.texImage2D(J.TEXTURE_2D,c,X0,Q0.width,Q0.height,0,N0,V0,Q0.data)}else if(R.isDataArrayTexture)if(A0){if(l0)$.texStorage3D(J.TEXTURE_2D_ARRAY,$0,X0,s.width,s.height,s.depth);if(S)if(R.layerUpdates.size>0){let c=pQ(s.width,s.height,R.format,R.type);for(let W0 of R.layerUpdates){let q0=s.data.subarray(W0*c/s.data.BYTES_PER_ELEMENT,(W0+1)*c/s.data.BYTES_PER_ELEMENT);$.texSubImage3D(J.TEXTURE_2D_ARRAY,0,0,0,W0,s.width,s.height,1,N0,V0,q0)}R.clearLayerUpdates()}else $.texSubImage3D(J.TEXTURE_2D_ARRAY,0,0,0,0,s.width,s.height,s.depth,N0,V0,s.data)}else $.texImage3D(J.TEXTURE_2D_ARRAY,0,X0,s.width,s.height,s.depth,0,N0,V0,s.data);else if(R.isData3DTexture)if(A0){if(l0)$.texStorage3D(J.TEXTURE_3D,$0,X0,s.width,s.height,s.depth);if(S)$.texSubImage3D(J.TEXTURE_3D,0,0,0,0,s.width,s.height,s.depth,N0,V0,s.data)}else $.texImage3D(J.TEXTURE_3D,0,X0,s.width,s.height,s.depth,0,N0,V0,s.data);else if(R.isFramebufferTexture){if(l0)if(A0)$.texStorage2D(J.TEXTURE_2D,$0,X0,s.width,s.height);else{let{width:c,height:W0}=s;for(let q0=0;q0<$0;q0++)$.texImage2D(J.TEXTURE_2D,q0,X0,c,W0,0,N0,V0,null),c>>=1,W0>>=1}}else if(R.isHTMLTexture){if("texElementImage2D"in J){let c=J.canvas;if(!c.hasAttribute("layoutsubtree"))c.setAttribute("layoutsubtree","true");if(s.parentNode!==c){c.appendChild(s),N.add(R),c.onpaint=(W0)=>{let q0=W0.changedElements;for(let a of N)if(q0.includes(a.image))a.needsUpdate=!0},c.requestPaint();return}if(J.texElementImage2D.length===3)J.texElementImage2D(J.TEXTURE_2D,J.RGBA8,s);else{let{RGBA:q0,RGBA:a,UNSIGNED_BYTE:K0}=J;J.texElementImage2D(J.TEXTURE_2D,0,q0,a,K0,s)}J.texParameteri(J.TEXTURE_2D,J.TEXTURE_MIN_FILTER,J.LINEAR),J.texParameteri(J.TEXTURE_2D,J.TEXTURE_WRAP_S,J.CLAMP_TO_EDGE),J.texParameteri(J.TEXTURE_2D,J.TEXTURE_WRAP_T,J.CLAMP_TO_EDGE)}}else if(I0.length>0){if(A0&&l0){let c=$J(I0[0]);$.texStorage2D(J.TEXTURE_2D,$0,X0,c.width,c.height)}for(let c=0,W0=I0.length;c<W0;c++)if(Q0=I0[c],A0){if(S)$.texSubImage2D(J.TEXTURE_2D,c,0,0,N0,V0,Q0)}else $.texImage2D(J.TEXTURE_2D,c,X0,N0,V0,Q0);R.generateMipmaps=!1}else if(A0){if(l0){let c=$J(s);$.texStorage2D(J.TEXTURE_2D,$0,X0,c.width,c.height)}if(S)$.texSubImage2D(J.TEXTURE_2D,0,0,0,N0,V0,s)}else $.texImage2D(J.TEXTURE_2D,0,X0,N0,V0,s);if(q(R))_(g);if(Y0.__version=J0.version,R.onUpdate)R.onUpdate(R)}L.__version=R.version}function p0(L,R,T){if(R.image.length!==6)return;let g=Z0(L,R),r=R.source;$.bindTexture(J.TEXTURE_CUBE_MAP,L.__webglTexture,J.TEXTURE0+T);let J0=Z.get(r);if(r.version!==J0.__version||g===!0){$.activeTexture(J.TEXTURE0+T);let Y0=h0.getPrimaries(h0.workingColorSpace),d=R.colorSpace===m9?null:h0.getPrimaries(R.colorSpace),s=R.colorSpace===m9||Y0===d?J.NONE:J.BROWSER_DEFAULT_WEBGL;$.pixelStorei(J.UNPACK_FLIP_Y_WEBGL,R.flipY),$.pixelStorei(J.UNPACK_PREMULTIPLY_ALPHA_WEBGL,R.premultiplyAlpha),$.pixelStorei(J.UNPACK_ALIGNMENT,R.unpackAlignment),$.pixelStorei(J.UNPACK_COLORSPACE_CONVERSION_WEBGL,s);let N0=R.isCompressedTexture||R.image[0].isCompressedTexture,V0=R.image[0]&&R.image[0].isDataTexture,X0=[];for(let a=0;a<6;a++){if(!N0&&!V0)X0[a]=F(R.image[a],!0,W.maxCubemapSize);else X0[a]=V0?R.image[a].image:R.image[a];X0[a]=c0(R,X0[a])}let Q0=X0[0],I0=K.convert(R.format,R.colorSpace),A0=K.convert(R.type),l0=V(R.internalFormat,I0,A0,R.normalized,R.colorSpace),S=R.isVideoTexture!==!0,$0=J0.__version===void 0||g===!0,c=r.dataReady,W0=I(R,Q0);i(J.TEXTURE_CUBE_MAP,R);let q0;if(N0){if(S&&$0)$.texStorage2D(J.TEXTURE_CUBE_MAP,W0,l0,Q0.width,Q0.height);for(let a=0;a<6;a++){q0=X0[a].mipmaps;for(let K0=0;K0<q0.length;K0++){let T0=q0[K0];if(R.format!==eJ)if(I0!==null)if(S){if(c)$.compressedTexSubImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0,0,0,T0.width,T0.height,I0,T0.data)}else $.compressedTexImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0,l0,T0.width,T0.height,0,T0.data);else C0("WebGLRenderer: Attempt to load unsupported compressed texture format in .setTextureCube()");else if(S){if(c)$.texSubImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0,0,0,T0.width,T0.height,I0,A0,T0.data)}else $.texImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0,l0,T0.width,T0.height,0,I0,A0,T0.data)}}}else{if(q0=R.mipmaps,S&&$0){if(q0.length>0)W0++;let a=$J(X0[0]);$.texStorage2D(J.TEXTURE_CUBE_MAP,W0,l0,a.width,a.height)}for(let a=0;a<6;a++)if(V0){if(S){if(c)$.texSubImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,0,0,0,X0[a].width,X0[a].height,I0,A0,X0[a].data)}else $.texImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,0,l0,X0[a].width,X0[a].height,0,I0,A0,X0[a].data);for(let K0=0;K0<q0.length;K0++){let HJ=q0[K0].image[a].image;if(S){if(c)$.texSubImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0+1,0,0,HJ.width,HJ.height,I0,A0,HJ.data)}else $.texImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0+1,l0,HJ.width,HJ.height,0,I0,A0,HJ.data)}}else{if(S){if(c)$.texSubImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,0,0,0,I0,A0,X0[a])}else $.texImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,0,l0,I0,A0,X0[a]);for(let K0=0;K0<q0.length;K0++){let T0=q0[K0];if(S){if(c)$.texSubImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0+1,0,0,I0,A0,T0.image[a])}else $.texImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+a,K0+1,l0,I0,A0,T0.image[a])}}}if(q(R))_(J.TEXTURE_CUBE_MAP);if(J0.__version=r.version,R.onUpdate)R.onUpdate(R)}L.__version=R.version}function f0(L,R,T,g,r,J0){let Y0=K.convert(T.format,T.colorSpace),d=K.convert(T.type),s=V(T.internalFormat,Y0,d,T.normalized,T.colorSpace),N0=Z.get(R),V0=Z.get(T);if(V0.__renderTarget=R,!N0.__hasExternalTextures){let X0=Math.max(1,R.width>>J0),Q0=Math.max(1,R.height>>J0);if(r===J.TEXTURE_3D||r===J.TEXTURE_2D_ARRAY)$.texImage3D(r,J0,s,X0,Q0,R.depth,0,Y0,d,null);else $.texImage2D(r,J0,s,X0,Q0,0,Y0,d,null)}if($.bindFramebuffer(J.FRAMEBUFFER,L),j(R))Y.framebufferTexture2DMultisampleEXT(J.FRAMEBUFFER,g,r,V0.__webglTexture,0,EJ(R));else if(r===J.TEXTURE_2D||r>=J.TEXTURE_CUBE_MAP_POSITIVE_X&&r<=J.TEXTURE_CUBE_MAP_NEGATIVE_Z)J.framebufferTexture2D(J.FRAMEBUFFER,g,r,V0.__webglTexture,J0);$.bindFramebuffer(J.FRAMEBUFFER,null)}function v0(L,R,T){if(J.bindRenderbuffer(J.RENDERBUFFER,L),R.depthBuffer){let g=R.depthTexture,r=g&&g.isDepthTexture?g.type:null,J0=A(R.stencilBuffer,r),Y0=R.stencilBuffer?J.DEPTH_STENCIL_ATTACHMENT:J.DEPTH_ATTACHMENT;if(j(R))Y.renderbufferStorageMultisampleEXT(J.RENDERBUFFER,EJ(R),J0,R.width,R.height);else if(T)J.renderbufferStorageMultisample(J.RENDERBUFFER,EJ(R),J0,R.width,R.height);else J.renderbufferStorage(J.RENDERBUFFER,J0,R.width,R.height);J.framebufferRenderbuffer(J.FRAMEBUFFER,Y0,J.RENDERBUFFER,L)}else{let g=R.textures;for(let r=0;r<g.length;r++){let J0=g[r],Y0=K.convert(J0.format,J0.colorSpace),d=K.convert(J0.type),s=V(J0.internalFormat,Y0,d,J0.normalized,J0.colorSpace);if(j(R))Y.renderbufferStorageMultisampleEXT(J.RENDERBUFFER,EJ(R),s,R.width,R.height);else if(T)J.renderbufferStorageMultisample(J.RENDERBUFFER,EJ(R),s,R.width,R.height);else J.renderbufferStorage(J.RENDERBUFFER,s,R.width,R.height)}}J.bindRenderbuffer(J.RENDERBUFFER,null)}function t0(L,R,T){let g=R.isWebGLCubeRenderTarget===!0;if($.bindFramebuffer(J.FRAMEBUFFER,L),!(R.depthTexture&&R.depthTexture.isDepthTexture))throw Error("THREE.WebGLTextures: renderTarget.depthTexture must be an instance of THREE.DepthTexture.");let r=Z.get(R.depthTexture);if(r.__renderTarget=R,!r.__webglTexture||R.depthTexture.image.width!==R.width||R.depthTexture.image.height!==R.height)R.depthTexture.image.width=R.width,R.depthTexture.image.height=R.height,R.depthTexture.needsUpdate=!0;if(g){if(r.__webglInit===void 0)r.__webglInit=!0,R.depthTexture.addEventListener("dispose",P);if(r.__webglTexture===void 0){r.__webglTexture=J.createTexture(),$.bindTexture(J.TEXTURE_CUBE_MAP,r.__webglTexture),i(J.TEXTURE_CUBE_MAP,R.depthTexture);let N0=K.convert(R.depthTexture.format),V0=K.convert(R.depthTexture.type),X0;if(R.depthTexture.format===x9)X0=J.DEPTH_COMPONENT24;else if(R.depthTexture.format===g9)X0=J.DEPTH24_STENCIL8;for(let Q0=0;Q0<6;Q0++)J.texImage2D(J.TEXTURE_CUBE_MAP_POSITIVE_X+Q0,0,X0,R.width,R.height,0,N0,V0,null)}}else t(R.depthTexture,0);let J0=r.__webglTexture,Y0=EJ(R),d=g?J.TEXTURE_CUBE_MAP_POSITIVE_X+T:J.TEXTURE_2D,s=R.depthTexture.format===g9?J.DEPTH_STENCIL_ATTACHMENT:J.DEPTH_ATTACHMENT;if(R.depthTexture.format===x9)if(j(R))Y.framebufferTexture2DMultisampleEXT(J.FRAMEBUFFER,s,d,J0,0,Y0);else J.framebufferTexture2D(J.FRAMEBUFFER,s,d,J0,0);else if(R.depthTexture.format===g9)if(j(R))Y.framebufferTexture2DMultisampleEXT(J.FRAMEBUFFER,s,d,J0,0,Y0);else J.framebufferTexture2D(J.FRAMEBUFFER,s,d,J0,0);else throw Error("THREE.WebGLTextures: Unknown depthTexture format.")}function m0(L){let R=Z.get(L),T=L.isWebGLCubeRenderTarget===!0;if(R.__boundDepthTexture!==L.depthTexture){let g=L.depthTexture;if(R.__depthDisposeCallback)R.__depthDisposeCallback();if(g){let r=()=>{delete R.__boundDepthTexture,delete R.__depthDisposeCallback,g.removeEventListener("dispose",r)};g.addEventListener("dispose",r),R.__depthDisposeCallback=r}R.__boundDepthTexture=g}if(L.depthTexture&&!R.__autoAllocateDepthBuffer)if(T)for(let g=0;g<6;g++)t0(R.__webglFramebuffer[g],L,g);else{let g=L.texture.mipmaps;if(g&&g.length>0)t0(R.__webglFramebuffer[0],L,0);else t0(R.__webglFramebuffer,L,0)}else if(T){R.__webglDepthbuffer=[];for(let g=0;g<6;g++)if($.bindFramebuffer(J.FRAMEBUFFER,R.__webglFramebuffer[g]),R.__webglDepthbuffer[g]===void 0)R.__webglDepthbuffer[g]=J.createRenderbuffer(),v0(R.__webglDepthbuffer[g],L,!1);else{let r=L.stencilBuffer?J.DEPTH_STENCIL_ATTACHMENT:J.DEPTH_ATTACHMENT,J0=R.__webglDepthbuffer[g];J.bindRenderbuffer(J.RENDERBUFFER,J0),J.framebufferRenderbuffer(J.FRAMEBUFFER,r,J.RENDERBUFFER,J0)}}else{let g=L.texture.mipmaps;if(g&&g.length>0)$.bindFramebuffer(J.FRAMEBUFFER,R.__webglFramebuffer[0]);else $.bindFramebuffer(J.FRAMEBUFFER,R.__webglFramebuffer);if(R.__webglDepthbuffer===void 0)R.__webglDepthbuffer=J.createRenderbuffer(),v0(R.__webglDepthbuffer,L,!1);else{let r=L.stencilBuffer?J.DEPTH_STENCIL_ATTACHMENT:J.DEPTH_ATTACHMENT,J0=R.__webglDepthbuffer;J.bindRenderbuffer(J.RENDERBUFFER,J0),J.framebufferRenderbuffer(J.FRAMEBUFFER,r,J.RENDERBUFFER,J0)}}$.bindFramebuffer(J.FRAMEBUFFER,null)}function b0(L,R,T){let g=Z.get(L);if(R!==void 0)f0(g.__webglFramebuffer,L,L.texture,J.COLOR_ATTACHMENT0,J.TEXTURE_2D,0);if(T!==void 0)m0(L)}function FJ(L){let R=L.texture,T=Z.get(L),g=Z.get(R);L.addEventListener("dispose",O);let r=L.textures,J0=L.isWebGLCubeRenderTarget===!0,Y0=r.length>1;if(!Y0){if(g.__webglTexture===void 0)g.__webglTexture=J.createTexture();g.__version=R.version,H.memory.textures++}if(J0){T.__webglFramebuffer=[];for(let d=0;d<6;d++)if(R.mipmaps&&R.mipmaps.length>0){T.__webglFramebuffer[d]=[];for(let s=0;s<R.mipmaps.length;s++)T.__webglFramebuffer[d][s]=J.createFramebuffer()}else T.__webglFramebuffer[d]=J.createFramebuffer()}else{if(R.mipmaps&&R.mipmaps.length>0){T.__webglFramebuffer=[];for(let d=0;d<R.mipmaps.length;d++)T.__webglFramebuffer[d]=J.createFramebuffer()}else T.__webglFramebuffer=J.createFramebuffer();if(Y0)for(let d=0,s=r.length;d<s;d++){let N0=Z.get(r[d]);if(N0.__webglTexture===void 0)N0.__webglTexture=J.createTexture(),H.memory.textures++}if(L.samples>0&&j(L)===!1){T.__webglMultisampledFramebuffer=J.createFramebuffer(),T.__webglColorRenderbuffer=[],$.bindFramebuffer(J.FRAMEBUFFER,T.__webglMultisampledFramebuffer);for(let d=0;d<r.length;d++){let s=r[d];T.__webglColorRenderbuffer[d]=J.createRenderbuffer(),J.bindRenderbuffer(J.RENDERBUFFER,T.__webglColorRenderbuffer[d]);let N0=K.convert(s.format,s.colorSpace),V0=K.convert(s.type),X0=V(s.internalFormat,N0,V0,s.normalized,s.colorSpace,L.isXRRenderTarget===!0),Q0=EJ(L);J.renderbufferStorageMultisample(J.RENDERBUFFER,Q0,X0,L.width,L.height),J.framebufferRenderbuffer(J.FRAMEBUFFER,J.COLOR_ATTACHMENT0+d,J.RENDERBUFFER,T.__webglColorRenderbuffer[d])}if(J.bindRenderbuffer(J.RENDERBUFFER,null),L.depthBuffer)T.__webglDepthRenderbuffer=J.createRenderbuffer(),v0(T.__webglDepthRenderbuffer,L,!0);$.bindFramebuffer(J.FRAMEBUFFER,null)}}if(J0){$.bindTexture(J.TEXTURE_CUBE_MAP,g.__webglTexture),i(J.TEXTURE_CUBE_MAP,R);for(let d=0;d<6;d++)if(R.mipmaps&&R.mipmaps.length>0)for(let s=0;s<R.mipmaps.length;s++)f0(T.__webglFramebuffer[d][s],L,R,J.COLOR_ATTACHMENT0,J.TEXTURE_CUBE_MAP_POSITIVE_X+d,s);else f0(T.__webglFramebuffer[d],L,R,J.COLOR_ATTACHMENT0,J.TEXTURE_CUBE_MAP_POSITIVE_X+d,0);if(q(R))_(J.TEXTURE_CUBE_MAP);$.unbindTexture()}else if(Y0){for(let d=0,s=r.length;d<s;d++){let N0=r[d],V0=Z.get(N0),X0=J.TEXTURE_2D;if(L.isWebGL3DRenderTarget||L.isWebGLArrayRenderTarget)X0=L.isWebGL3DRenderTarget?J.TEXTURE_3D:J.TEXTURE_2D_ARRAY;if($.bindTexture(X0,V0.__webglTexture),i(X0,N0),f0(T.__webglFramebuffer,L,N0,J.COLOR_ATTACHMENT0+d,X0,0),q(N0))_(X0)}$.unbindTexture()}else{let d=J.TEXTURE_2D;if(L.isWebGL3DRenderTarget||L.isWebGLArrayRenderTarget)d=L.isWebGL3DRenderTarget?J.TEXTURE_3D:J.TEXTURE_2D_ARRAY;if($.bindTexture(d,g.__webglTexture),i(d,R),R.mipmaps&&R.mipmaps.length>0)for(let s=0;s<R.mipmaps.length;s++)f0(T.__webglFramebuffer[s],L,R,J.COLOR_ATTACHMENT0,d,s);else f0(T.__webglFramebuffer,L,R,J.COLOR_ATTACHMENT0,d,0);if(q(R))_(d);$.unbindTexture()}if(L.depthBuffer)m0(L)}function yJ(L){let R=L.textures;for(let T=0,g=R.length;T<g;T++){let r=R[T];if(q(r)){let J0=w(L),Y0=Z.get(r).__webglTexture;$.bindTexture(J0,Y0),_(J0),$.unbindTexture()}}}let QJ=[],OJ=[];function DJ(L){if(L.samples>0){if(j(L)===!1){let{textures:R,width:T,height:g}=L,r=J.COLOR_BUFFER_BIT,J0=L.stencilBuffer?J.DEPTH_STENCIL_ATTACHMENT:J.DEPTH_ATTACHMENT,Y0=Z.get(L),d=R.length>1;if(d)for(let N0=0;N0<R.length;N0++)$.bindFramebuffer(J.FRAMEBUFFER,Y0.__webglMultisampledFramebuffer),J.framebufferRenderbuffer(J.FRAMEBUFFER,J.COLOR_ATTACHMENT0+N0,J.RENDERBUFFER,null),$.bindFramebuffer(J.FRAMEBUFFER,Y0.__webglFramebuffer),J.framebufferTexture2D(J.DRAW_FRAMEBUFFER,J.COLOR_ATTACHMENT0+N0,J.TEXTURE_2D,null,0);$.bindFramebuffer(J.READ_FRAMEBUFFER,Y0.__webglMultisampledFramebuffer);let s=L.texture.mipmaps;if(s&&s.length>0)$.bindFramebuffer(J.DRAW_FRAMEBUFFER,Y0.__webglFramebuffer[0]);else $.bindFramebuffer(J.DRAW_FRAMEBUFFER,Y0.__webglFramebuffer);for(let N0=0;N0<R.length;N0++){if(L.resolveDepthBuffer){if(L.depthBuffer)r|=J.DEPTH_BUFFER_BIT;if(L.stencilBuffer&&L.resolveStencilBuffer)r|=J.STENCIL_BUFFER_BIT}if(d){J.framebufferRenderbuffer(J.READ_FRAMEBUFFER,J.COLOR_ATTACHMENT0,J.RENDERBUFFER,Y0.__webglColorRenderbuffer[N0]);let V0=Z.get(R[N0]).__webglTexture;J.framebufferTexture2D(J.DRAW_FRAMEBUFFER,J.COLOR_ATTACHMENT0,J.TEXTURE_2D,V0,0)}if(J.blitFramebuffer(0,0,T,g,0,0,T,g,r,J.NEAREST),X===!0){if(QJ.length=0,OJ.length=0,QJ.push(J.COLOR_ATTACHMENT0+N0),L.depthBuffer&&L.resolveDepthBuffer===!1)QJ.push(J0),OJ.push(J0),J.invalidateFramebuffer(J.DRAW_FRAMEBUFFER,OJ);J.invalidateFramebuffer(J.READ_FRAMEBUFFER,QJ)}}if($.bindFramebuffer(J.READ_FRAMEBUFFER,null),$.bindFramebuffer(J.DRAW_FRAMEBUFFER,null),d)for(let N0=0;N0<R.length;N0++){$.bindFramebuffer(J.FRAMEBUFFER,Y0.__webglMultisampledFramebuffer),J.framebufferRenderbuffer(J.FRAMEBUFFER,J.COLOR_ATTACHMENT0+N0,J.RENDERBUFFER,Y0.__webglColorRenderbuffer[N0]);let V0=Z.get(R[N0]).__webglTexture;$.bindFramebuffer(J.FRAMEBUFFER,Y0.__webglFramebuffer),J.framebufferTexture2D(J.DRAW_FRAMEBUFFER,J.COLOR_ATTACHMENT0+N0,J.TEXTURE_2D,V0,0)}$.bindFramebuffer(J.DRAW_FRAMEBUFFER,Y0.__webglMultisampledFramebuffer)}else if(L.depthBuffer&&L.resolveDepthBuffer===!1&&X){let R=L.stencilBuffer?J.DEPTH_STENCIL_ATTACHMENT:J.DEPTH_ATTACHMENT;J.invalidateFramebuffer(J.DRAW_FRAMEBUFFER,[R])}}}function EJ(L){return Math.min(W.maxSamples,L.samples)}function j(L){let R=Z.get(L);return L.samples>0&&Q.has("WEBGL_multisampled_render_to_texture")===!0&&R.__useRenderToTexture!==!1}function fJ(L){let R=H.render.frame;if(E.get(L)!==R)E.set(L,R),L.update()}function c0(L,R){let{colorSpace:T,format:g,type:r}=L;if(L.isCompressedTexture===!0||L.isVideoTexture===!0)return R;if(T!==GQ&&T!==m9)if(h0.getTransfer(T)===r0){if(g!==eJ||r!==nJ)C0("WebGLTextures: sRGB encoded textures have to use RGBAFormat and UnsignedByteType.")}else _0("WebGLTextures: Unsupported texture color space:",T);return R}function $J(L){if(typeof HTMLImageElement<"u"&&L instanceof HTMLImageElement)U.width=L.naturalWidth||L.width,U.height=L.naturalHeight||L.height;else if(typeof VideoFrame<"u"&&L instanceof VideoFrame)U.width=L.displayWidth,U.height=L.displayHeight;else U.width=L.width,U.height=L.height;return U}this.allocateTextureUnit=u,this.resetTextureUnits=o,this.getTextureUnits=p,this.setTextureUnits=n,this.setTexture2D=t,this.setTexture2DArray=e,this.setTexture3D=H0,this.setTextureCube=M0,this.rebindTextures=b0,this.setupRenderTarget=FJ,this.updateRenderTargetMipmap=yJ,this.updateMultisampleRenderTarget=DJ,this.setupDepthRenderbuffer=m0,this.setupFrameBufferTexture=f0,this.useMultisampledRTT=j,this.isReversedDepthBuffer=function(){return $.buffers.depth.getReversed()}}function oU(J,Q){function $(Z,W=m9){let K,H=h0.getTransfer(W);if(Z===nJ)return J.UNSIGNED_BYTE;if(Z===_7)return J.UNSIGNED_SHORT_4_4_4_4;if(Z===P7)return J.UNSIGNED_SHORT_5_5_5_1;if(Z===kZ)return J.UNSIGNED_INT_5_9_9_9_REV;if(Z===MZ)return J.UNSIGNED_INT_10F_11F_11F_REV;if(Z===RZ)return J.BYTE;if(Z===OZ)return J.SHORT;if(Z===T8)return J.UNSIGNED_SHORT;if(Z===C7)return J.INT;if(Z===C9)return J.UNSIGNED_INT;if(Z===G9)return J.FLOAT;if(Z===E9)return J.HALF_FLOAT;if(Z===LZ)return J.ALPHA;if(Z===VZ)return J.RGB;if(Z===eJ)return J.RGBA;if(Z===x9)return J.DEPTH_COMPONENT;if(Z===g9)return J.DEPTH_STENCIL;if(Z===BZ)return J.RED;if(Z===T7)return J.RED_INTEGER;if(Z===p9)return J.RG;if(Z===S7)return J.RG_INTEGER;if(Z===j7)return J.RGBA_INTEGER;if(Z===D6||Z===R6||Z===O6||Z===k6)if(H===r0)if(K=Q.get("WEBGL_compressed_texture_s3tc_srgb"),K!==null){if(Z===D6)return K.COMPRESSED_SRGB_S3TC_DXT1_EXT;if(Z===R6)return K.COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT;if(Z===O6)return K.COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT;if(Z===k6)return K.COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT}else return null;else if(K=Q.get("WEBGL_compressed_texture_s3tc"),K!==null){if(Z===D6)return K.COMPRESSED_RGB_S3TC_DXT1_EXT;if(Z===R6)return K.COMPRESSED_RGBA_S3TC_DXT1_EXT;if(Z===O6)return K.COMPRESSED_RGBA_S3TC_DXT3_EXT;if(Z===k6)return K.COMPRESSED_RGBA_S3TC_DXT5_EXT}else return null;if(Z===y7||Z===f7||Z===v7||Z===b7)if(K=Q.get("WEBGL_compressed_texture_pvrtc"),K!==null){if(Z===y7)return K.COMPRESSED_RGB_PVRTC_4BPPV1_IMG;if(Z===f7)return K.COMPRESSED_RGB_PVRTC_2BPPV1_IMG;if(Z===v7)return K.COMPRESSED_RGBA_PVRTC_4BPPV1_IMG;if(Z===b7)return K.COMPRESSED_RGBA_PVRTC_2BPPV1_IMG}else return null;if(Z===h7||Z===x7||Z===g7||Z===p7||Z===m7||Z===M6||Z===d7)if(K=Q.get("WEBGL_compressed_texture_etc"),K!==null){if(Z===h7||Z===x7)return H===r0?K.COMPRESSED_SRGB8_ETC2:K.COMPRESSED_RGB8_ETC2;if(Z===g7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ETC2_EAC:K.COMPRESSED_RGBA8_ETC2_EAC;if(Z===p7)return K.COMPRESSED_R11_EAC;if(Z===m7)return K.COMPRESSED_SIGNED_R11_EAC;if(Z===M6)return K.COMPRESSED_RG11_EAC;if(Z===d7)return K.COMPRESSED_SIGNED_RG11_EAC}else return null;if(Z===l7||Z===u7||Z===c7||Z===n7||Z===s7||Z===i7||Z===o7||Z===a7||Z===r7||Z===t7||Z===e7||Z===JQ||Z===QQ||Z===$Q)if(K=Q.get("WEBGL_compressed_texture_astc"),K!==null){if(Z===l7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR:K.COMPRESSED_RGBA_ASTC_4x4_KHR;if(Z===u7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR:K.COMPRESSED_RGBA_ASTC_5x4_KHR;if(Z===c7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR:K.COMPRESSED_RGBA_ASTC_5x5_KHR;if(Z===n7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR:K.COMPRESSED_RGBA_ASTC_6x5_KHR;if(Z===s7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR:K.COMPRESSED_RGBA_ASTC_6x6_KHR;if(Z===i7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR:K.COMPRESSED_RGBA_ASTC_8x5_KHR;if(Z===o7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR:K.COMPRESSED_RGBA_ASTC_8x6_KHR;if(Z===a7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR:K.COMPRESSED_RGBA_ASTC_8x8_KHR;if(Z===r7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR:K.COMPRESSED_RGBA_ASTC_10x5_KHR;if(Z===t7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR:K.COMPRESSED_RGBA_ASTC_10x6_KHR;if(Z===e7)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR:K.COMPRESSED_RGBA_ASTC_10x8_KHR;if(Z===JQ)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR:K.COMPRESSED_RGBA_ASTC_10x10_KHR;if(Z===QQ)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR:K.COMPRESSED_RGBA_ASTC_12x10_KHR;if(Z===$Q)return H===r0?K.COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR:K.COMPRESSED_RGBA_ASTC_12x12_KHR}else return null;if(Z===ZQ||Z===WQ||Z===KQ)if(K=Q.get("EXT_texture_compression_bptc"),K!==null){if(Z===ZQ)return H===r0?K.COMPRESSED_SRGB_ALPHA_BPTC_UNORM_EXT:K.COMPRESSED_RGBA_BPTC_UNORM_EXT;if(Z===WQ)return K.COMPRESSED_RGB_BPTC_SIGNED_FLOAT_EXT;if(Z===KQ)return K.COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT_EXT}else return null;if(Z===HQ||Z===YQ||Z===L6||Z===XQ)if(K=Q.get("EXT_texture_compression_rgtc"),K!==null){if(Z===HQ)return K.COMPRESSED_RED_RGTC1_EXT;if(Z===YQ)return K.COMPRESSED_SIGNED_RED_RGTC1_EXT;if(Z===L6)return K.COMPRESSED_RED_GREEN_RGTC2_EXT;if(Z===XQ)return K.COMPRESSED_SIGNED_RED_GREEN_RGTC2_EXT}else return null;if(Z===D8)return J.UNSIGNED_INT_24_8;return J[Z]!==void 0?J[Z]:null}return{convert:$}}var aU=`
void main() {

	gl_Position = vec4( position, 1.0 );

}`,rU=`
uniform sampler2DArray depthColor;
uniform float depthWidth;
uniform float depthHeight;

void main() {

	vec2 coord = vec2( gl_FragCoord.x / depthWidth, gl_FragCoord.y / depthHeight );

	if ( coord.x >= 1.0 ) {

		gl_FragDepth = texture( depthColor, vec3( coord.x - 1.0, coord.y, 1 ) ).r;

	} else {

		gl_FragDepth = texture( depthColor, vec3( coord.x, coord.y, 0 ) ).r;

	}

}`;class kW{constructor(){this.texture=null,this.mesh=null,this.depthNear=0,this.depthFar=0}init(J,Q){if(this.texture===null){let $=new y6(J.texture);if(J.depthNear!==Q.depthNear||J.depthFar!==Q.depthFar)this.depthNear=J.depthNear,this.depthFar=J.depthFar;this.texture=$}}getMesh(J){if(this.texture!==null){if(this.mesh===null){let Q=J.cameras[0].viewport,$=new gJ({vertexShader:aU,fragmentShader:rU,uniforms:{depthColor:{value:this.texture},depthWidth:{value:Q.z},depthHeight:{value:Q.w}}});this.mesh=new sJ(new v8(20,20),$)}}return this.mesh}reset(){this.texture=null,this.mesh=null}getDepthTexture(){return this.texture}}class MW extends N9{constructor(J,Q){super();let $=this,Z=null,W=1,K=null,H="local-floor",Y=1,X=null,U=null,E=null,N=null,G=null,D=null,M=typeof XRWebGLBinding<"u",z=new kW,F={},q=Q.getContextAttributes(),_=null,w=null,V=[],A=[],I=new u0,P=null,O=new IJ;O.viewport=new KJ;let B=new IJ;B.viewport=new KJ;let l=[O,B],C=new bQ,m=null,o=null;this.cameraAutoUpdate=!0,this.enabled=!1,this.isPresenting=!1,this.getController=function(i){let Z0=V[i];if(Z0===void 0)Z0=new y8,V[i]=Z0;return Z0.getTargetRaySpace()},this.getControllerGrip=function(i){let Z0=V[i];if(Z0===void 0)Z0=new y8,V[i]=Z0;return Z0.getGripSpace()},this.getHand=function(i){let Z0=V[i];if(Z0===void 0)Z0=new y8,V[i]=Z0;return Z0.getHandSpace()};function p(i){let Z0=A.indexOf(i.inputSource);if(Z0===-1)return;let F0=V[Z0];if(F0!==void 0)F0.update(i.inputSource,i.frame,X||K),F0.dispatchEvent({type:i.type,data:i.inputSource})}function n(){Z.removeEventListener("select",p),Z.removeEventListener("selectstart",p),Z.removeEventListener("selectend",p),Z.removeEventListener("squeeze",p),Z.removeEventListener("squeezestart",p),Z.removeEventListener("squeezeend",p),Z.removeEventListener("end",n),Z.removeEventListener("inputsourceschange",u);for(let i=0;i<V.length;i++){let Z0=A[i];if(Z0===null)continue;A[i]=null,V[i].disconnect(Z0)}m=null,o=null,z.reset();for(let i in F)delete F[i];J.setRenderTarget(_),G=null,N=null,E=null,Z=null,w=null,i0.stop(),$.isPresenting=!1,J.setPixelRatio(P),J.setSize(I.width,I.height,!1),$.dispatchEvent({type:"sessionend"})}this.setFramebufferScaleFactor=function(i){if(W=i,$.isPresenting===!0)C0("WebXRManager: Cannot change framebuffer scale while presenting.")},this.setReferenceSpaceType=function(i){if(H=i,$.isPresenting===!0)C0("WebXRManager: Cannot change reference space type while presenting.")},this.getReferenceSpace=function(){return X||K},this.setReferenceSpace=function(i){X=i},this.getBaseLayer=function(){return N!==null?N:G},this.getBinding=function(){if(E===null&&M)E=new XRWebGLBinding(Z,Q);return E},this.getFrame=function(){return D},this.getSession=function(){return Z},this.setSession=async function(i){if(Z=i,Z!==null){if(_=J.getRenderTarget(),Z.addEventListener("select",p),Z.addEventListener("selectstart",p),Z.addEventListener("selectend",p),Z.addEventListener("squeeze",p),Z.addEventListener("squeezestart",p),Z.addEventListener("squeezeend",p),Z.addEventListener("end",n),Z.addEventListener("inputsourceschange",u),q.xrCompatible!==!0)await Q.makeXRCompatible();if(P=J.getPixelRatio(),J.getSize(I),!(M&&("createProjectionLayer"in XRWebGLBinding.prototype))){let F0={antialias:q.antialias,alpha:!0,depth:q.depth,stencil:q.stencil,framebufferScaleFactor:W};G=new XRWebGLLayer(Z,Q,F0),Z.updateRenderState({baseLayer:G}),J.setPixelRatio(1),J.setSize(G.framebufferWidth,G.framebufferHeight,!1),w=new xJ(G.framebufferWidth,G.framebufferHeight,{format:eJ,type:nJ,colorSpace:J.outputColorSpace,stencilBuffer:q.stencil,resolveDepthBuffer:G.ignoreDepthValues===!1,resolveStencilBuffer:G.ignoreDepthValues===!1})}else{let F0=null,D0=null,w0=null;if(q.depth)w0=q.stencil?Q.DEPTH24_STENCIL8:Q.DEPTH_COMPONENT24,F0=q.stencil?g9:x9,D0=q.stencil?D8:C9;let p0={colorFormat:Q.RGBA8,depthFormat:w0,scaleFactor:W};E=this.getBinding(),N=E.createProjectionLayer(p0),Z.updateRenderState({layers:[N]}),J.setPixelRatio(1),J.setSize(N.textureWidth,N.textureHeight,!1),w=new xJ(N.textureWidth,N.textureHeight,{format:eJ,type:nJ,depthTexture:new _9(N.textureWidth,N.textureHeight,D0,void 0,void 0,void 0,void 0,void 0,void 0,F0),stencilBuffer:q.stencil,colorSpace:J.outputColorSpace,samples:q.antialias?4:0,resolveDepthBuffer:N.ignoreDepthValues===!1,resolveStencilBuffer:N.ignoreDepthValues===!1})}w.isXRRenderTarget=!0,this.setFoveation(Y),X=null,K=await Z.requestReferenceSpace(H),i0.setContext(Z),i0.start(),$.isPresenting=!0,$.dispatchEvent({type:"sessionstart"})}},this.getEnvironmentBlendMode=function(){if(Z!==null)return Z.environmentBlendMode},this.getDepthTexture=function(){return z.getDepthTexture()};function u(i){for(let Z0=0;Z0<i.removed.length;Z0++){let F0=i.removed[Z0],D0=A.indexOf(F0);if(D0>=0)A[D0]=null,V[D0].disconnect(F0)}for(let Z0=0;Z0<i.added.length;Z0++){let F0=i.added[Z0],D0=A.indexOf(F0);if(D0===-1){for(let p0=0;p0<V.length;p0++)if(p0>=A.length){A.push(F0),D0=p0;break}else if(A[p0]===null){A[p0]=F0,D0=p0;break}if(D0===-1)break}let w0=V[D0];if(w0)w0.connect(F0)}}let h=new b,t=new b;function e(i,Z0,F0){h.setFromMatrixPosition(Z0.matrixWorld),t.setFromMatrixPosition(F0.matrixWorld);let D0=h.distanceTo(t),w0=Z0.projectionMatrix.elements,p0=F0.projectionMatrix.elements,f0=w0[14]/(w0[10]-1),v0=w0[14]/(w0[10]+1),t0=(w0[9]+1)/w0[5],m0=(w0[9]-1)/w0[5],b0=(w0[8]-1)/w0[0],FJ=(p0[8]+1)/p0[0],yJ=f0*b0,QJ=f0*FJ,OJ=D0/(-b0+FJ),DJ=OJ*-b0;if(Z0.matrixWorld.decompose(i.position,i.quaternion,i.scale),i.translateX(DJ),i.translateZ(OJ),i.matrixWorld.compose(i.position,i.quaternion,i.scale),i.matrixWorldInverse.copy(i.matrixWorld).invert(),w0[10]===-1)i.projectionMatrix.copy(Z0.projectionMatrix),i.projectionMatrixInverse.copy(Z0.projectionMatrixInverse);else{let EJ=f0+OJ,j=v0+OJ,fJ=yJ-DJ,c0=QJ+(D0-DJ),$J=t0*v0/j*EJ,L=m0*v0/j*EJ;i.projectionMatrix.makePerspective(fJ,c0,$J,L,EJ,j),i.projectionMatrixInverse.copy(i.projectionMatrix).invert()}}function H0(i,Z0){if(Z0===null)i.matrixWorld.copy(i.matrix);else i.matrixWorld.multiplyMatrices(Z0.matrixWorld,i.matrix);i.matrixWorldInverse.copy(i.matrixWorld).invert()}this.updateCamera=function(i){if(Z===null)return;let{near:Z0,far:F0}=i;if(z.texture!==null){if(z.depthNear>0)Z0=z.depthNear;if(z.depthFar>0)F0=z.depthFar}if(C.near=B.near=O.near=Z0,C.far=B.far=O.far=F0,m!==C.near||o!==C.far)Z.updateRenderState({depthNear:C.near,depthFar:C.far}),m=C.near,o=C.far;C.layers.mask=i.layers.mask|6,O.layers.mask=C.layers.mask&-5,B.layers.mask=C.layers.mask&-3;let D0=i.parent,w0=C.cameras;H0(C,D0);for(let p0=0;p0<w0.length;p0++)H0(w0[p0],D0);if(w0.length===2)e(C,O,B);else C.projectionMatrix.copy(O.projectionMatrix);M0(i,C,D0)};function M0(i,Z0,F0){if(F0===null)i.matrix.copy(Z0.matrixWorld);else i.matrix.copy(F0.matrixWorld),i.matrix.invert(),i.matrix.multiply(Z0.matrixWorld);if(i.matrix.decompose(i.position,i.quaternion,i.scale),i.updateMatrixWorld(!0),i.projectionMatrix.copy(Z0.projectionMatrix),i.projectionMatrixInverse.copy(Z0.projectionMatrixInverse),i.isPerspectiveCamera)i.fov=G6*2*Math.atan(1/i.projectionMatrix.elements[5]),i.zoom=1}this.getCamera=function(){return C},this.getFoveation=function(){if(N===null&&G===null)return;return Y},this.setFoveation=function(i){if(Y=i,N!==null)N.fixedFoveation=i;if(G!==null&&G.fixedFoveation!==void 0)G.fixedFoveation=i},this.hasDepthSensing=function(){return z.texture!==null},this.getDepthSensingMesh=function(){return z.getMesh(C)},this.getCameraTexture=function(i){return F[i]};let k0=null;function ZJ(i,Z0){if(U=Z0.getViewerPose(X||K),D=Z0,U!==null){let F0=U.views;if(G!==null)J.setRenderTargetFramebuffer(w,G.framebuffer),J.setRenderTarget(w);let D0=!1;if(F0.length!==C.cameras.length)C.cameras.length=0,D0=!0;for(let v0=0;v0<F0.length;v0++){let t0=F0[v0],m0=null;if(G!==null)m0=G.getViewport(t0);else{let FJ=E.getViewSubImage(N,t0);if(m0=FJ.viewport,v0===0)J.setRenderTargetTextures(w,FJ.colorTexture,FJ.depthStencilTexture),J.setRenderTarget(w)}let b0=l[v0];if(b0===void 0)b0=new IJ,b0.layers.enable(v0),b0.viewport=new KJ,l[v0]=b0;if(b0.matrix.fromArray(t0.transform.matrix),b0.matrix.decompose(b0.position,b0.quaternion,b0.scale),b0.projectionMatrix.fromArray(t0.projectionMatrix),b0.projectionMatrixInverse.copy(b0.projectionMatrix).invert(),b0.viewport.set(m0.x,m0.y,m0.width,m0.height),v0===0)C.matrix.copy(b0.matrix),C.matrix.decompose(C.position,C.quaternion,C.scale);if(D0===!0)C.cameras.push(b0)}let w0=Z.enabledFeatures;if(w0&&w0.includes("depth-sensing")&&Z.depthUsage=="gpu-optimized"&&M){E=$.getBinding();let v0=E.getDepthInformation(F0[0]);if(v0&&v0.isValid&&v0.texture)z.init(v0,Z.renderState)}if(w0&&w0.includes("camera-access")&&M){J.state.unbindTexture(),E=$.getBinding();for(let v0=0;v0<F0.length;v0++){let t0=F0[v0].camera;if(t0){let m0=F[t0];if(!m0)m0=new y6,F[t0]=m0;let b0=E.getCameraImage(t0);m0.sourceTexture=b0}}}}for(let F0=0;F0<V.length;F0++){let D0=A[F0],w0=V[F0];if(D0!==null&&w0!==void 0)w0.update(D0,Z0,X||K)}if(k0)k0(i,Z0);if(Z0.detectedPlanes)$.dispatchEvent({type:"planesdetected",data:Z0});D=null}let i0=new YW;i0.setAnimationLoop(ZJ),this.setAnimationLoop=function(i){k0=i},this.dispose=function(){}}}var tU=new WJ,LW=new P0;LW.set(-1,0,0,0,1,0,0,0,1);function eU(J,Q){function $(F,q){if(F.matrixAutoUpdate===!0)F.updateMatrix();q.value.copy(F.matrix)}function Z(F,q){if(q.color.getRGB(F.fogColor.value,LQ(J)),q.isFog)F.fogNear.value=q.near,F.fogFar.value=q.far;else if(q.isFogExp2)F.fogDensity.value=q.density}function W(F,q,_,w,V){if(q.isNodeMaterial)q.uniformsNeedUpdate=!1;else if(q.isMeshBasicMaterial)K(F,q);else if(q.isMeshLambertMaterial){if(K(F,q),q.envMap)F.envMapIntensity.value=q.envMapIntensity}else if(q.isMeshToonMaterial)K(F,q),N(F,q);else if(q.isMeshPhongMaterial){if(K(F,q),E(F,q),q.envMap)F.envMapIntensity.value=q.envMapIntensity}else if(q.isMeshStandardMaterial){if(K(F,q),G(F,q),q.isMeshPhysicalMaterial)D(F,q,V)}else if(q.isMeshMatcapMaterial)K(F,q),M(F,q);else if(q.isMeshDepthMaterial)K(F,q);else if(q.isMeshDistanceMaterial)K(F,q),z(F,q);else if(q.isMeshNormalMaterial)K(F,q);else if(q.isLineBasicMaterial){if(H(F,q),q.isLineDashedMaterial)Y(F,q)}else if(q.isPointsMaterial)X(F,q,_,w);else if(q.isSpriteMaterial)U(F,q);else if(q.isShadowMaterial)F.color.value.copy(q.color),F.opacity.value=q.opacity;else if(q.isShaderMaterial)q.uniformsNeedUpdate=!1}function K(F,q){if(F.opacity.value=q.opacity,q.color)F.diffuse.value.copy(q.color);if(q.emissive)F.emissive.value.copy(q.emissive).multiplyScalar(q.emissiveIntensity);if(q.map)F.map.value=q.map,$(q.map,F.mapTransform);if(q.alphaMap)F.alphaMap.value=q.alphaMap,$(q.alphaMap,F.alphaMapTransform);if(q.bumpMap){if(F.bumpMap.value=q.bumpMap,$(q.bumpMap,F.bumpMapTransform),F.bumpScale.value=q.bumpScale,q.side===CJ)F.bumpScale.value*=-1}if(q.normalMap){if(F.normalMap.value=q.normalMap,$(q.normalMap,F.normalMapTransform),F.normalScale.value.copy(q.normalScale),q.side===CJ)F.normalScale.value.negate()}if(q.displacementMap)F.displacementMap.value=q.displacementMap,$(q.displacementMap,F.displacementMapTransform),F.displacementScale.value=q.displacementScale,F.displacementBias.value=q.displacementBias;if(q.emissiveMap)F.emissiveMap.value=q.emissiveMap,$(q.emissiveMap,F.emissiveMapTransform);if(q.specularMap)F.specularMap.value=q.specularMap,$(q.specularMap,F.specularMapTransform);if(q.alphaTest>0)F.alphaTest.value=q.alphaTest;let _=Q.get(q),w=_.envMap,V=_.envMapRotation;if(w){if(F.envMap.value=w,F.envMapRotation.value.setFromMatrix4(tU.makeRotationFromEuler(V)).transpose(),w.isCubeTexture&&w.isRenderTargetTexture===!1)F.envMapRotation.value.premultiply(LW);F.reflectivity.value=q.reflectivity,F.ior.value=q.ior,F.refractionRatio.value=q.refractionRatio}if(q.lightMap)F.lightMap.value=q.lightMap,F.lightMapIntensity.value=q.lightMapIntensity,$(q.lightMap,F.lightMapTransform);if(q.aoMap)F.aoMap.value=q.aoMap,F.aoMapIntensity.value=q.aoMapIntensity,$(q.aoMap,F.aoMapTransform)}function H(F,q){if(F.diffuse.value.copy(q.color),F.opacity.value=q.opacity,q.map)F.map.value=q.map,$(q.map,F.mapTransform)}function Y(F,q){F.dashSize.value=q.dashSize,F.totalSize.value=q.dashSize+q.gapSize,F.scale.value=q.scale}function X(F,q,_,w){if(F.diffuse.value.copy(q.color),F.opacity.value=q.opacity,F.size.value=q.size*_,F.scale.value=w*0.5,q.map)F.map.value=q.map,$(q.map,F.uvTransform);if(q.alphaMap)F.alphaMap.value=q.alphaMap,$(q.alphaMap,F.alphaMapTransform);if(q.alphaTest>0)F.alphaTest.value=q.alphaTest}function U(F,q){if(F.diffuse.value.copy(q.color),F.opacity.value=q.opacity,F.rotation.value=q.rotation,q.map)F.map.value=q.map,$(q.map,F.mapTransform);if(q.alphaMap)F.alphaMap.value=q.alphaMap,$(q.alphaMap,F.alphaMapTransform);if(q.alphaTest>0)F.alphaTest.value=q.alphaTest}function E(F,q){F.specular.value.copy(q.specular),F.shininess.value=Math.max(q.shininess,0.0001)}function N(F,q){if(q.gradientMap)F.gradientMap.value=q.gradientMap}function G(F,q){if(F.metalness.value=q.metalness,q.metalnessMap)F.metalnessMap.value=q.metalnessMap,$(q.metalnessMap,F.metalnessMapTransform);if(F.roughness.value=q.roughness,q.roughnessMap)F.roughnessMap.value=q.roughnessMap,$(q.roughnessMap,F.roughnessMapTransform);if(q.envMap)F.envMapIntensity.value=q.envMapIntensity}function D(F,q,_){if(F.ior.value=q.ior,q.sheen>0){if(F.sheenColor.value.copy(q.sheenColor).multiplyScalar(q.sheen),F.sheenRoughness.value=q.sheenRoughness,q.sheenColorMap)F.sheenColorMap.value=q.sheenColorMap,$(q.sheenColorMap,F.sheenColorMapTransform);if(q.sheenRoughnessMap)F.sheenRoughnessMap.value=q.sheenRoughnessMap,$(q.sheenRoughnessMap,F.sheenRoughnessMapTransform)}if(q.clearcoat>0){if(F.clearcoat.value=q.clearcoat,F.clearcoatRoughness.value=q.clearcoatRoughness,q.clearcoatMap)F.clearcoatMap.value=q.clearcoatMap,$(q.clearcoatMap,F.clearcoatMapTransform);if(q.clearcoatRoughnessMap)F.clearcoatRoughnessMap.value=q.clearcoatRoughnessMap,$(q.clearcoatRoughnessMap,F.clearcoatRoughnessMapTransform);if(q.clearcoatNormalMap){if(F.clearcoatNormalMap.value=q.clearcoatNormalMap,$(q.clearcoatNormalMap,F.clearcoatNormalMapTransform),F.clearcoatNormalScale.value.copy(q.clearcoatNormalScale),q.side===CJ)F.clearcoatNormalScale.value.negate()}}if(q.dispersion>0)F.dispersion.value=q.dispersion;if(q.iridescence>0){if(F.iridescence.value=q.iridescence,F.iridescenceIOR.value=q.iridescenceIOR,F.iridescenceThicknessMinimum.value=q.iridescenceThicknessRange[0],F.iridescenceThicknessMaximum.value=q.iridescenceThicknessRange[1],q.iridescenceMap)F.iridescenceMap.value=q.iridescenceMap,$(q.iridescenceMap,F.iridescenceMapTransform);if(q.iridescenceThicknessMap)F.iridescenceThicknessMap.value=q.iridescenceThicknessMap,$(q.iridescenceThicknessMap,F.iridescenceThicknessMapTransform)}if(q.transmission>0){if(F.transmission.value=q.transmission,F.transmissionSamplerMap.value=_.texture,F.transmissionSamplerSize.value.set(_.width,_.height),q.transmissionMap)F.transmissionMap.value=q.transmissionMap,$(q.transmissionMap,F.transmissionMapTransform);if(F.thickness.value=q.thickness,q.thicknessMap)F.thicknessMap.value=q.thicknessMap,$(q.thicknessMap,F.thicknessMapTransform);F.attenuationDistance.value=q.attenuationDistance,F.attenuationColor.value.copy(q.attenuationColor)}if(q.anisotropy>0){if(F.anisotropyVector.value.set(q.anisotropy*Math.cos(q.anisotropyRotation),q.anisotropy*Math.sin(q.anisotropyRotation)),q.anisotropyMap)F.anisotropyMap.value=q.anisotropyMap,$(q.anisotropyMap,F.anisotropyMapTransform)}if(F.specularIntensity.value=q.specularIntensity,F.specularColor.value.copy(q.specularColor),q.specularColorMap)F.specularColorMap.value=q.specularColorMap,$(q.specularColorMap,F.specularColorMapTransform);if(q.specularIntensityMap)F.specularIntensityMap.value=q.specularIntensityMap,$(q.specularIntensityMap,F.specularIntensityMapTransform)}function M(F,q){if(q.matcap)F.matcap.value=q.matcap}function z(F,q){let _=Q.get(q).light;F.referencePosition.value.setFromMatrixPosition(_.matrixWorld),F.nearDistance.value=_.shadow.camera.near,F.farDistance.value=_.shadow.camera.far}return{refreshFogUniforms:Z,refreshMaterialUniforms:W}}function JG(J,Q,$,Z){let W={},K={},H=[],Y=J.getParameter(J.MAX_UNIFORM_BUFFER_BINDINGS);function X(V,A){let I=A.program;Z.uniformBlockBinding(V,I)}function U(V,A){let I=W[V.id];if(I===void 0)F(V),I=E(V),W[V.id]=I,V.addEventListener("dispose",_);let P=A.program;Z.updateUBOMapping(V,P);let O=Q.render.frame;if(K[V.id]!==O)G(V),K[V.id]=O}function E(V){let A=N();V.__bindingPointIndex=A;let I=J.createBuffer(),P=V.__size,O=V.usage;return J.bindBuffer(J.UNIFORM_BUFFER,I),J.bufferData(J.UNIFORM_BUFFER,P,O),J.bindBuffer(J.UNIFORM_BUFFER,null),J.bindBufferBase(J.UNIFORM_BUFFER,A,I),I}function N(){for(let V=0;V<Y;V++)if(H.indexOf(V)===-1)return H.push(V),V;return _0("WebGLRenderer: Maximum number of simultaneously usable uniforms groups reached."),0}function G(V){let A=W[V.id],I=V.uniforms,P=V.__cache;J.bindBuffer(J.UNIFORM_BUFFER,A);for(let O=0,B=I.length;O<B;O++){let l=I[O];if(Array.isArray(l))for(let C=0,m=l.length;C<m;C++)D(l[C],O,C,P);else D(l,O,0,P)}J.bindBuffer(J.UNIFORM_BUFFER,null)}function D(V,A,I,P){if(z(V,A,I,P)===!0){let{__offset:O,value:B}=V;if(Array.isArray(B)){let l=0;for(let C=0;C<B.length;C++){let m=B[C],o=q(m);if(M(m,V.__data,l),typeof m!=="number"&&typeof m!=="boolean"&&!m.isMatrix3&&!ArrayBuffer.isView(m))l+=o.storage/Float32Array.BYTES_PER_ELEMENT}}else M(B,V.__data,0);J.bufferSubData(J.UNIFORM_BUFFER,O,V.__data)}}function M(V,A,I){if(typeof V==="number"||typeof V==="boolean")A[0]=V;else if(V.isMatrix3)A[0]=V.elements[0],A[1]=V.elements[1],A[2]=V.elements[2],A[3]=0,A[4]=V.elements[3],A[5]=V.elements[4],A[6]=V.elements[5],A[7]=0,A[8]=V.elements[6],A[9]=V.elements[7],A[10]=V.elements[8],A[11]=0;else if(ArrayBuffer.isView(V))A.set(new V.constructor(V.buffer,V.byteOffset,A.length));else V.toArray(A,I)}function z(V,A,I,P){let O=V.value,B=A+"_"+I;if(P[B]===void 0){if(typeof O==="number"||typeof O==="boolean")P[B]=O;else if(ArrayBuffer.isView(O))P[B]=O.slice();else P[B]=O.clone();return!0}else{let l=P[B];if(typeof O==="number"||typeof O==="boolean"){if(l!==O)return P[B]=O,!0}else if(ArrayBuffer.isView(O))return!0;else if(l.equals(O)===!1)return l.copy(O),!0}return!1}function F(V){let A=V.uniforms,I=0,P=16;for(let B=0,l=A.length;B<l;B++){let C=Array.isArray(A[B])?A[B]:[A[B]];for(let m=0,o=C.length;m<o;m++){let p=C[m],n=Array.isArray(p.value)?p.value:[p.value];for(let u=0,h=n.length;u<h;u++){let t=n[u],e=q(t),H0=I%P,M0=H0%e.boundary,k0=H0+M0;if(I+=M0,k0!==0&&P-k0<e.storage)I+=P-k0;p.__data=new Float32Array(e.storage/Float32Array.BYTES_PER_ELEMENT),p.__offset=I,I+=e.storage}}}let O=I%P;if(O>0)I+=P-O;return V.__size=I,V.__cache={},this}function q(V){let A={boundary:0,storage:0};if(typeof V==="number"||typeof V==="boolean")A.boundary=4,A.storage=4;else if(V.isVector2)A.boundary=8,A.storage=8;else if(V.isVector3||V.isColor)A.boundary=16,A.storage=12;else if(V.isVector4)A.boundary=16,A.storage=16;else if(V.isMatrix3)A.boundary=48,A.storage=48;else if(V.isMatrix4)A.boundary=64,A.storage=64;else if(V.isTexture)C0("WebGLRenderer: Texture samplers can not be part of an uniforms group.");else if(ArrayBuffer.isView(V))A.boundary=16,A.storage=V.byteLength;else C0("WebGLRenderer: Unsupported uniform value type.",V);return A}function _(V){let A=V.target;A.removeEventListener("dispose",_);let I=H.indexOf(A.__bindingPointIndex);H.splice(I,1),J.deleteBuffer(W[A.id]),delete W[A.id],delete K[A.id]}function w(){for(let V in W)J.deleteBuffer(W[V]);H=[],W={},K={}}return{bind:X,update:U,dispose:w}}var QG=new Uint16Array([12469,15057,12620,14925,13266,14620,13807,14376,14323,13990,14545,13625,14713,13328,14840,12882,14931,12528,14996,12233,15039,11829,15066,11525,15080,11295,15085,10976,15082,10705,15073,10495,13880,14564,13898,14542,13977,14430,14158,14124,14393,13732,14556,13410,14702,12996,14814,12596,14891,12291,14937,11834,14957,11489,14958,11194,14943,10803,14921,10506,14893,10278,14858,9960,14484,14039,14487,14025,14499,13941,14524,13740,14574,13468,14654,13106,14743,12678,14818,12344,14867,11893,14889,11509,14893,11180,14881,10751,14852,10428,14812,10128,14765,9754,14712,9466,14764,13480,14764,13475,14766,13440,14766,13347,14769,13070,14786,12713,14816,12387,14844,11957,14860,11549,14868,11215,14855,10751,14825,10403,14782,10044,14729,9651,14666,9352,14599,9029,14967,12835,14966,12831,14963,12804,14954,12723,14936,12564,14917,12347,14900,11958,14886,11569,14878,11247,14859,10765,14828,10401,14784,10011,14727,9600,14660,9289,14586,8893,14508,8533,15111,12234,15110,12234,15104,12216,15092,12156,15067,12010,15028,11776,14981,11500,14942,11205,14902,10752,14861,10393,14812,9991,14752,9570,14682,9252,14603,8808,14519,8445,14431,8145,15209,11449,15208,11451,15202,11451,15190,11438,15163,11384,15117,11274,15055,10979,14994,10648,14932,10343,14871,9936,14803,9532,14729,9218,14645,8742,14556,8381,14461,8020,14365,7603,15273,10603,15272,10607,15267,10619,15256,10631,15231,10614,15182,10535,15118,10389,15042,10167,14963,9787,14883,9447,14800,9115,14710,8665,14615,8318,14514,7911,14411,7507,14279,7198,15314,9675,15313,9683,15309,9712,15298,9759,15277,9797,15229,9773,15166,9668,15084,9487,14995,9274,14898,8910,14800,8539,14697,8234,14590,7790,14479,7409,14367,7067,14178,6621,15337,8619,15337,8631,15333,8677,15325,8769,15305,8871,15264,8940,15202,8909,15119,8775,15022,8565,14916,8328,14804,8009,14688,7614,14569,7287,14448,6888,14321,6483,14088,6171,15350,7402,15350,7419,15347,7480,15340,7613,15322,7804,15287,7973,15229,8057,15148,8012,15046,7846,14933,7611,14810,7357,14682,7069,14552,6656,14421,6316,14251,5948,14007,5528,15356,5942,15356,5977,15353,6119,15348,6294,15332,6551,15302,6824,15249,7044,15171,7122,15070,7050,14949,6861,14818,6611,14679,6349,14538,6067,14398,5651,14189,5311,13935,4958,15359,4123,15359,4153,15356,4296,15353,4646,15338,5160,15311,5508,15263,5829,15188,6042,15088,6094,14966,6001,14826,5796,14678,5543,14527,5287,14377,4985,14133,4586,13869,4257,15360,1563,15360,1642,15358,2076,15354,2636,15341,3350,15317,4019,15273,4429,15203,4732,15105,4911,14981,4932,14836,4818,14679,4621,14517,4386,14359,4156,14083,3795,13808,3437,15360,122,15360,137,15358,285,15355,636,15344,1274,15322,2177,15281,2765,15215,3223,15120,3451,14995,3569,14846,3567,14681,3466,14511,3305,14344,3121,14037,2800,13753,2467,15360,0,15360,1,15359,21,15355,89,15346,253,15325,479,15287,796,15225,1148,15133,1492,15008,1749,14856,1882,14685,1886,14506,1783,14324,1608,13996,1398,13702,1183]),J9=null;function $G(){if(J9===null)J9=new kQ(QG,16,16,p9,E9),J9.name="DFG_LUT",J9.minFilter=_J,J9.magFilter=_J,J9.wrapS=q6,J9.wrapT=q6,J9.generateMipmaps=!1,J9.needsUpdate=!0;return J9}class rQ{constructor(J={}){let{canvas:Q=SZ(),context:$=null,depth:Z=!0,stencil:W=!1,alpha:K=!1,antialias:H=!1,premultipliedAlpha:Y=!0,preserveDrawingBuffer:X=!1,powerPreference:U="default",failIfMajorPerformanceCaveat:E=!1,reversedDepthBuffer:N=!1,outputBufferType:G=nJ}=J;this.isWebGLRenderer=!0;let D;if($!==null){if(typeof WebGLRenderingContext<"u"&&$ instanceof WebGLRenderingContext)throw Error("THREE.WebGLRenderer: WebGL 1 is not supported since r163.");D=$.getContextAttributes().alpha}else D=K;let M=G,z=new Set([j7,S7,T7]),F=new Set([nJ,C9,T8,D8,_7,P7]),q=new Uint32Array(4),_=new Int32Array(4),w=new b,V=null,A=null,I=[],P=[],O=null;this.domElement=Q,this.debug={checkShaderErrors:!0,onShaderError:null},this.autoClear=!0,this.autoClearColor=!0,this.autoClearDepth=!0,this.autoClearStencil=!0,this.sortObjects=!0,this.clippingPlanes=[],this.localClippingEnabled=!1,this.toneMapping=cJ,this.toneMappingExposure=1,this.transmissionResolutionScale=1;let B=this,l=!1,C=null,m=null,o=null,p=null;this._outputColorSpace=IZ;let n=0,u=0,h=null,t=-1,e=null,H0=new KJ,M0=new KJ,k0=null,ZJ=new g0(0),i0=0,i=Q.width,Z0=Q.height,F0=1,D0=null,w0=null,p0=new KJ(0,0,i,Z0),f0=new KJ(0,0,i,Z0),v0=!1,t0=new T6,m0=!1,b0=!1,FJ=new WJ,yJ=new b,QJ=new KJ,OJ={background:null,fog:null,environment:null,overrideMaterial:null,isScene:!0},DJ=!1;function EJ(){return h===null?F0:1}let j=$;function fJ(k,y){return Q.getContext(k,y)}try{let k={alpha:!0,depth:Z,stencil:W,antialias:H,premultipliedAlpha:Y,preserveDrawingBuffer:X,powerPreference:U,failIfMajorPerformanceCaveat:E};if("setAttribute"in Q)Q.setAttribute("data-engine",`three.js r${y$}`);if(Q.addEventListener("webglcontextlost",T0,!1),Q.addEventListener("webglcontextrestored",HJ,!1),Q.addEventListener("webglcontextcreationerror",e0,!1),j===null){if(j=fJ("webgl2",k),j===null)if(fJ("webgl2"))throw Error("THREE.WebGLRenderer: Error creating WebGL context with your selected attributes.");else throw Error("THREE.WebGLRenderer: Error creating WebGL context.")}}catch(k){throw _0("WebGLRenderer: "+k.message),k}let c0,$J,L,R,T,g,r,J0,Y0,d,s,N0,V0,X0,Q0,I0,A0,l0,S,$0,c,W0,q0;function a(){if(c0=new UX(j),c0.init(),c=new oU(j,c0),$J=new QX(j,c0,J,c),L=new sU(j,c0),$J.reversedDepthBuffer&&N)L.buffers.depth.setReversed(!0);m=j.createFramebuffer(),o=j.createFramebuffer(),p=j.createFramebuffer(),R=new NX(j),T=new yU,g=new iU(j,c0,L,T,$J,c,R),r=new XX(B),J0=new RK(j),W0=new eY(j,J0),Y0=new GX(j,J0,R,W0),d=new FX(j,Y0,J0,W0,R),l0=new qX(j,$J,g),Q0=new $X(T),s=new jU(B,r,c0,$J,W0,Q0),N0=new eU(B,T),V0=new vU,X0=new mU(c0),A0=new tY(B,r,L,d,D,Y),I0=new nU(B,d,$J),q0=new JG(j,R,$J,L),S=new JX(j,c0,R),$0=new EX(j,c0,R),R.programs=s.programs,B.capabilities=$J,B.extensions=c0,B.properties=T,B.renderLists=V0,B.shadowMap=I0,B.state=L,B.info=R}if(a(),M!==nJ)O=new RX(M,Q.width,Q.height,H,Z,W);let K0=new MW(B,j);this.xr=K0,this.getContext=function(){return j},this.getContextAttributes=function(){return j.getContextAttributes()},this.forceContextLoss=function(){let k=c0.get("WEBGL_lose_context");if(k)k.loseContext()},this.forceContextRestore=function(){let k=c0.get("WEBGL_lose_context");if(k)k.restoreContext()},this.getPixelRatio=function(){return F0},this.setPixelRatio=function(k){if(k===void 0)return;F0=k,this.setSize(i,Z0,!1)},this.getSize=function(k){return k.set(i,Z0)},this.setSize=function(k,y,x=!0){if(K0.isPresenting){C0("WebGLRenderer: Can't change size while VR device is presenting.");return}if(i=k,Z0=y,Q.width=Math.floor(k*F0),Q.height=Math.floor(y*F0),x===!0)Q.style.width=k+"px",Q.style.height=y+"px";if(O!==null)O.setSize(Q.width,Q.height);this.setViewport(0,0,k,y)},this.getDrawingBufferSize=function(k){return k.set(i*F0,Z0*F0).floor()},this.setDrawingBufferSize=function(k,y,x){i=k,Z0=y,F0=x,Q.width=Math.floor(k*x),Q.height=Math.floor(y*x),this.setViewport(0,0,k,y)},this.setEffects=function(k){if(M===nJ){_0("WebGLRenderer: setEffects() requires outputBufferType set to HalfFloatType or FloatType.");return}if(k){for(let y=0;y<k.length;y++)if(k[y].isOutputPass===!0){C0("WebGLRenderer: OutputPass is not needed in setEffects(). Tone mapping and color space conversion are applied automatically.");break}}O.setEffects(k||[])},this.getCurrentViewport=function(k){return k.copy(H0)},this.getViewport=function(k){return k.copy(p0)},this.setViewport=function(k,y,x,f){if(k.isVector4)p0.set(k.x,k.y,k.z,k.w);else p0.set(k,y,x,f);L.viewport(H0.copy(p0).multiplyScalar(F0).round())},this.getScissor=function(k){return k.copy(f0)},this.setScissor=function(k,y,x,f){if(k.isVector4)f0.set(k.x,k.y,k.z,k.w);else f0.set(k,y,x,f);L.scissor(M0.copy(f0).multiplyScalar(F0).round())},this.getScissorTest=function(){return v0},this.setScissorTest=function(k){L.setScissorTest(v0=k)},this.setOpaqueSort=function(k){D0=k},this.setTransparentSort=function(k){w0=k},this.getClearColor=function(k){return k.copy(A0.getClearColor())},this.setClearColor=function(){A0.setClearColor(...arguments)},this.getClearAlpha=function(){return A0.getClearAlpha()},this.setClearAlpha=function(){A0.setClearAlpha(...arguments)},this.clear=function(k=!0,y=!0,x=!0){let f=0;if(k){let v=!1;if(h!==null){let E0=h.texture.format;v=z.has(E0)}if(v){let E0=h.texture.type,O0=F.has(E0),G0=A0.getClearColor(),L0=A0.getClearAlpha(),B0=G0.r,S0=G0.g,y0=G0.b;if(O0)q[0]=B0,q[1]=S0,q[2]=y0,q[3]=L0,j.clearBufferuiv(j.COLOR,0,q);else _[0]=B0,_[1]=S0,_[2]=y0,_[3]=L0,j.clearBufferiv(j.COLOR,0,_)}else f|=j.COLOR_BUFFER_BIT}if(y)f|=j.DEPTH_BUFFER_BIT,this.state.buffers.depth.setMask(!0);if(x)f|=j.STENCIL_BUFFER_BIT,this.state.buffers.stencil.setMask(4294967295);if(f!==0)j.clear(f)},this.clearColor=function(){this.clear(!0,!1,!1)},this.clearDepth=function(){this.clear(!1,!0,!1)},this.clearStencil=function(){this.clear(!1,!1,!0)},this.setNodesHandler=function(k){k.setRenderer(this),C=k},this.dispose=function(){Q.removeEventListener("webglcontextlost",T0,!1),Q.removeEventListener("webglcontextrestored",HJ,!1),Q.removeEventListener("webglcontextcreationerror",e0,!1),A0.dispose(),V0.dispose(),X0.dispose(),T.dispose(),r.dispose(),d.dispose(),W0.dispose(),q0.dispose(),s.dispose(),K0.dispose(),K0.removeEventListener("sessionstart",eQ),K0.removeEventListener("sessionend",J$),T9.stop()};function T0(k){k.preventDefault(),FQ("WebGLRenderer: Context Lost."),l=!0}function HJ(){FQ("WebGLRenderer: Context Restored."),l=!1;let k=R.autoReset,y=I0.enabled,x=I0.autoUpdate,f=I0.needsUpdate,v=I0.type;a(),R.autoReset=k,I0.enabled=y,I0.autoUpdate=x,I0.needsUpdate=f,I0.type=v}function e0(k){_0("WebGLRenderer: A WebGL context could not be created. Reason: ",k.statusMessage)}function iJ(k){let y=k.target;y.removeEventListener("dispose",iJ),$9(y)}function $9(k){zW(k),T.remove(k)}function zW(k){let y=T.get(k).programs;if(y!==void 0){if(y.forEach(function(x){s.releaseProgram(x)}),k.isShaderMaterial)s.releaseShaderCache(k)}}this.renderBufferDirect=function(k,y,x,f,v,E0){if(y===null)y=OJ;let O0=v.isMesh&&v.matrixWorld.determinantAffine()<0,G0=wW(k,y,x,f,v);L.setMaterial(f,O0);let L0=x.index,B0=1;if(f.wireframe===!0){if(L0=Y0.getWireframeAttribute(x),L0===void 0)return;B0=2}let S0=x.drawRange,y0=x.attributes.position,z0=S0.start*B0,s0=(S0.start+S0.count)*B0;if(E0!==null)z0=Math.max(z0,E0.start*B0),s0=Math.min(s0,(E0.start+E0.count)*B0);if(L0!==null)z0=Math.max(z0,0),s0=Math.min(s0,L0.count);else if(y0!==void 0&&y0!==null)z0=Math.max(z0,0),s0=Math.min(s0,y0.count);let XJ=s0-z0;if(XJ<0||XJ===1/0)return;W0.setup(v,f,G0,x,L0);let YJ,o0=S;if(L0!==null)YJ=J0.get(L0),o0=$0,o0.setIndex(YJ);if(v.isMesh)if(f.wireframe===!0)L.setLineWidth(f.wireframeLinewidth*EJ()),o0.setMode(j.LINES);else o0.setMode(j.TRIANGLES);else if(v.isLine){let kJ=f.linewidth;if(kJ===void 0)kJ=1;if(L.setLineWidth(kJ*EJ()),v.isLineSegments)o0.setMode(j.LINES);else if(v.isLineLoop)o0.setMode(j.LINE_LOOP);else o0.setMode(j.LINE_STRIP)}else if(v.isPoints)o0.setMode(j.POINTS);else if(v.isSprite)o0.setMode(j.TRIANGLES);if(v.isBatchedMesh)if(!c0.get("WEBGL_multi_draw")){let{_multiDrawStarts:kJ,_multiDrawCounts:R0,_multiDrawCount:PJ}=v,d0=L0?J0.get(L0).bytesPerElement:1,vJ=T.get(f).currentProgram.getUniforms();for(let oJ=0;oJ<PJ;oJ++)vJ.setValue(j,"_gl_DrawID",oJ),o0.render(kJ[oJ]/d0,R0[oJ])}else o0.renderMultiDraw(v._multiDrawStarts,v._multiDrawCounts,v._multiDrawCount);else if(v.isInstancedMesh)o0.renderInstances(z0,XJ,v.count);else if(x.isInstancedBufferGeometry){let kJ=x._maxInstanceCount!==void 0?x._maxInstanceCount:1/0,R0=Math.min(x.instanceCount,kJ);o0.renderInstances(z0,XJ,R0)}else o0.render(z0,XJ)};function tQ(k,y,x){if(k.transparent===!0&&k.side===rJ&&k.forceSinglePass===!1)k.side=CJ,k.needsUpdate=!0,m8(k,y,x),k.side=N8,k.needsUpdate=!0,m8(k,y,x),k.side=rJ;else m8(k,y,x)}this.compile=function(k,y,x=null){if(x===null)x=k;if(A=X0.get(x),A.init(y),P.push(A),x.traverseVisible(function(v){if(v.isLight&&v.layers.test(y.layers)){if(A.pushLight(v),v.castShadow)A.pushShadow(v)}}),k!==x)k.traverseVisible(function(v){if(v.isLight&&v.layers.test(y.layers)){if(A.pushLight(v),v.castShadow)A.pushShadow(v)}});A.setupLights();let f=new Set;return k.traverse(function(v){if(!(v.isMesh||v.isPoints||v.isLine||v.isSprite))return;let E0=v.material;if(E0)if(Array.isArray(E0))for(let O0=0;O0<E0.length;O0++){let G0=E0[O0];tQ(G0,x,v),f.add(G0)}else tQ(E0,x,v),f.add(E0)}),A=P.pop(),f},this.compileAsync=function(k,y,x=null){let f=this.compile(k,y,x);return new Promise((v)=>{function E0(){if(f.forEach(function(O0){if(T.get(O0).currentProgram.isReady())f.delete(O0)}),f.size===0){v(k);return}setTimeout(E0,10)}if(c0.get("KHR_parallel_shader_compile")!==null)E0();else setTimeout(E0,10)})};let l6=null;function IW(k){if(l6)l6(k)}function eQ(){T9.stop()}function J$(){T9.start()}let T9=new YW;if(T9.setAnimationLoop(IW),typeof self<"u")T9.setContext(self);this.setAnimationLoop=function(k){l6=k,K0.setAnimationLoop(k),k===null?T9.stop():T9.start()},K0.addEventListener("sessionstart",eQ),K0.addEventListener("sessionend",J$),this.render=function(k,y){if(y!==void 0&&y.isCamera!==!0){_0("WebGLRenderer.render: camera is not an instance of THREE.Camera.");return}if(l===!0)return;if(C!==null)C.renderStart(k,y);let x=K0.enabled===!0&&K0.isPresenting===!0,f=O!==null&&(h===null||x)&&O.begin(B,h);if(k.matrixWorldAutoUpdate===!0)k.updateMatrixWorld();if(y.parent===null&&y.matrixWorldAutoUpdate===!0)y.updateMatrixWorld();if(K0.enabled===!0&&K0.isPresenting===!0&&(O===null||O.isCompositing()===!1)){if(K0.cameraAutoUpdate===!0)K0.updateCamera(y);y=K0.getCamera()}if(k.isScene===!0)k.onBeforeRender(B,k,y,h);if(A=X0.get(k,P.length),A.init(y),A.state.textureUnits=g.getTextureUnits(),P.push(A),FJ.multiplyMatrices(y.projectionMatrix,y.matrixWorldInverse),t0.setFromProjectionMatrix(FJ,qQ,y.reversedDepth),b0=this.localClippingEnabled,m0=Q0.init(this.clippingPlanes,b0),V=V0.get(k,I.length),V.init(),I.push(V),K0.enabled===!0&&K0.isPresenting===!0){let O0=B.xr.getDepthSensingMesh();if(O0!==null)u6(O0,y,-1/0,B.sortObjects)}if(u6(k,y,0,B.sortObjects),V.finish(),B.sortObjects===!0)V.sort(D0,w0,y.reversedDepth);if(DJ=K0.enabled===!1||K0.isPresenting===!1||K0.hasDepthSensing()===!1,DJ)A0.addToRenderList(V,k);if(this.info.render.frame++,this.info.autoReset===!0)this.info.reset();if(m0===!0)Q0.beginShadows();let v=A.state.shadowsArray;if(I0.render(v,k,y),m0===!0)Q0.endShadows();if((f&&O.hasRenderPass())===!1){let{opaque:O0,transmissive:G0}=V;if(A.setupLights(),y.isArrayCamera){let L0=y.cameras;if(G0.length>0)for(let B0=0,S0=L0.length;B0<S0;B0++){let y0=L0[B0];$$(O0,G0,k,y0)}if(DJ)A0.render(k);for(let B0=0,S0=L0.length;B0<S0;B0++){let y0=L0[B0];Q$(V,k,y0,y0.viewport)}}else{if(G0.length>0)$$(O0,G0,k,y);if(DJ)A0.render(k);Q$(V,k,y)}}if(h!==null&&u===0)g.updateMultisampleRenderTarget(h),g.updateRenderTargetMipmap(h);if(f)O.end(B);if(k.isScene===!0)k.onAfterRender(B,k,y);if(W0.resetDefaultState(),t=-1,e=null,P.pop(),P.length>0){if(A=P[P.length-1],g.setTextureUnits(A.state.textureUnits),m0===!0)Q0.setGlobalState(B.clippingPlanes,A.state.camera)}else A=null;if(I.pop(),I.length>0)V=I[I.length-1];else V=null;if(C!==null)C.renderEnd()};function u6(k,y,x,f){if(k.visible===!1)return;if(k.layers.test(y.layers)){if(k.isGroup)x=k.renderOrder;else if(k.isLOD){if(k.autoUpdate===!0)k.update(y)}else if(k.isLightProbeGrid)A.pushLightProbeGrid(k);else if(k.isLight){if(A.pushLight(k),k.castShadow)A.pushShadow(k)}else if(k.isSprite){if(!k.frustumCulled||t0.intersectsSprite(k)){if(f)QJ.setFromMatrixPosition(k.matrixWorld).applyMatrix4(FJ);let O0=d.update(k),G0=k.material;if(G0.visible)V.push(k,O0,G0,x,QJ.z,null)}}else if(k.isMesh||k.isLine||k.isPoints){if(!k.frustumCulled||t0.intersectsObject(k)){let O0=d.update(k),G0=k.material;if(f){if(k.boundingSphere!==void 0){if(k.boundingSphere===null)k.computeBoundingSphere();QJ.copy(k.boundingSphere.center)}else{if(O0.boundingSphere===null)O0.computeBoundingSphere();QJ.copy(O0.boundingSphere.center)}QJ.applyMatrix4(k.matrixWorld).applyMatrix4(FJ)}if(Array.isArray(G0)){let L0=O0.groups;for(let B0=0,S0=L0.length;B0<S0;B0++){let y0=L0[B0],z0=G0[y0.materialIndex];if(z0&&z0.visible)V.push(k,O0,z0,x,QJ.z,y0)}}else if(G0.visible)V.push(k,O0,G0,x,QJ.z,null)}}}let E0=k.children;for(let O0=0,G0=E0.length;O0<G0;O0++)u6(E0[O0],y,x,f)}function Q$(k,y,x,f){let{opaque:v,transmissive:E0,transparent:O0}=k;if(A.setupLightsView(x),m0===!0)Q0.setGlobalState(B.clippingPlanes,x);if(f)L.viewport(H0.copy(f));if(v.length>0)p8(v,y,x);if(E0.length>0)p8(E0,y,x);if(O0.length>0)p8(O0,y,x);L.buffers.depth.setTest(!0),L.buffers.depth.setMask(!0),L.buffers.color.setMask(!0),L.setPolygonOffset(!1)}function $$(k,y,x,f){if((x.isScene===!0?x.overrideMaterial:null)!==null)return;if(A.state.transmissionRenderTarget[f.id]===void 0){let z0=c0.has("EXT_color_buffer_half_float")||c0.has("EXT_color_buffer_float");A.state.transmissionRenderTarget[f.id]=new xJ(1,1,{generateMipmaps:!0,type:z0?E9:nJ,minFilter:h9,samples:Math.max(4,$J.samples),stencilBuffer:W,resolveDepthBuffer:!1,resolveStencilBuffer:!1,colorSpace:h0.workingColorSpace})}let E0=A.state.transmissionRenderTarget[f.id],O0=f.viewport||H0;E0.setSize(O0.z*B.transmissionResolutionScale,O0.w*B.transmissionResolutionScale);let G0=B.getRenderTarget(),L0=B.getActiveCubeFace(),B0=B.getActiveMipmapLevel();if(B.setRenderTarget(E0),B.getClearColor(ZJ),i0=B.getClearAlpha(),i0<1)B.setClearColor(16777215,0.5);if(B.clear(),DJ)A0.render(x);let S0=B.toneMapping;B.toneMapping=cJ;let y0=f.viewport;if(f.viewport!==void 0)f.viewport=void 0;if(A.setupLightsView(f),m0===!0)Q0.setGlobalState(B.clippingPlanes,f);if(p8(k,x,f),g.updateMultisampleRenderTarget(E0),g.updateRenderTargetMipmap(E0),c0.has("WEBGL_multisampled_render_to_texture")===!1){let z0=!1;for(let s0=0,XJ=y.length;s0<XJ;s0++){let YJ=y[s0],{object:o0,geometry:kJ,material:R0,group:PJ}=YJ;if(R0.side===rJ&&o0.layers.test(f.layers)){let d0=R0.side;R0.side=CJ,R0.needsUpdate=!0,Z$(o0,x,f,kJ,R0,PJ),R0.side=d0,R0.needsUpdate=!0,z0=!0}}if(z0===!0)g.updateMultisampleRenderTarget(E0),g.updateRenderTargetMipmap(E0)}if(B.setRenderTarget(G0,L0,B0),B.setClearColor(ZJ,i0),y0!==void 0)f.viewport=y0;B.toneMapping=S0}function p8(k,y,x){let f=y.isScene===!0?y.overrideMaterial:null;for(let v=0,E0=k.length;v<E0;v++){let O0=k[v],{object:G0,geometry:L0,group:B0}=O0,S0=O0.material;if(S0.allowOverride===!0&&f!==null)S0=f;if(G0.layers.test(x.layers))Z$(G0,y,x,L0,S0,B0)}}function Z$(k,y,x,f,v,E0){if(k.onBeforeRender(B,y,x,f,v,E0),k.modelViewMatrix.multiplyMatrices(x.matrixWorldInverse,k.matrixWorld),k.normalMatrix.getNormalMatrix(k.modelViewMatrix),v.onBeforeRender(B,y,x,f,k,E0),v.transparent===!0&&v.side===rJ&&v.forceSinglePass===!1)v.side=CJ,v.needsUpdate=!0,B.renderBufferDirect(x,y,f,v,k,E0),v.side=N8,v.needsUpdate=!0,B.renderBufferDirect(x,y,f,v,k,E0),v.side=rJ;else B.renderBufferDirect(x,y,f,v,k,E0);k.onAfterRender(B,y,x,f,v,E0)}function m8(k,y,x){if(y.isScene!==!0)y=OJ;let f=T.get(k),v=A.state.lights,E0=A.state.shadowsArray,O0=v.state.version,G0=s.getParameters(k,v.state,E0,y,x,A.state.lightProbeGridArray),L0=s.getProgramCacheKey(G0),B0=f.programs;f.environment=k.isMeshStandardMaterial||k.isMeshLambertMaterial||k.isMeshPhongMaterial?y.environment:null,f.fog=y.fog;let S0=k.isMeshStandardMaterial||k.isMeshLambertMaterial&&!k.envMap||k.isMeshPhongMaterial&&!k.envMap;if(f.envMap=r.get(k.envMap||f.environment,S0),f.envMapRotation=f.environment!==null&&k.envMap===null?y.environmentRotation:k.envMapRotation,B0===void 0)k.addEventListener("dispose",iJ),B0=new Map,f.programs=B0;let y0=B0.get(L0);if(y0!==void 0){if(f.currentProgram===y0&&f.lightsStateVersion===O0)return K$(k,G0),y0}else{if(G0.uniforms=s.getUniforms(k),C!==null&&k.isNodeMaterial)C.build(k,x,G0);k.onBeforeCompile(G0,B),y0=s.acquireProgram(G0,L0),B0.set(L0,y0),f.uniforms=G0.uniforms}let z0=f.uniforms;if(!k.isShaderMaterial&&!k.isRawShaderMaterial||k.clipping===!0)z0.clippingPlanes=Q0.uniform;if(K$(k,G0),f.needsLights=_W(k),f.lightsStateVersion=O0,f.needsLights)z0.ambientLightColor.value=v.state.ambient,z0.lightProbe.value=v.state.probe,z0.directionalLights.value=v.state.directional,z0.directionalLightShadows.value=v.state.directionalShadow,z0.spotLights.value=v.state.spot,z0.spotLightShadows.value=v.state.spotShadow,z0.rectAreaLights.value=v.state.rectArea,z0.ltc_1.value=v.state.rectAreaLTC1,z0.ltc_2.value=v.state.rectAreaLTC2,z0.pointLights.value=v.state.point,z0.pointLightShadows.value=v.state.pointShadow,z0.hemisphereLights.value=v.state.hemi,z0.directionalShadowMatrix.value=v.state.directionalShadowMatrix,z0.spotLightMatrix.value=v.state.spotLightMatrix,z0.spotLightMap.value=v.state.spotLightMap,z0.pointShadowMatrix.value=v.state.pointShadowMatrix;return f.lightProbeGrid=A.state.lightProbeGridArray.length>0,f.currentProgram=y0,f.uniformsList=null,y0}function W$(k){if(k.uniformsList===null){let y=k.currentProgram.getUniforms();k.uniformsList=g8.seqWithValue(y.seq,k.uniforms)}return k.uniformsList}function K$(k,y){let x=T.get(k);x.outputColorSpace=y.outputColorSpace,x.batching=y.batching,x.batchingColor=y.batchingColor,x.instancing=y.instancing,x.instancingColor=y.instancingColor,x.instancingMorph=y.instancingMorph,x.skinning=y.skinning,x.morphTargets=y.morphTargets,x.morphNormals=y.morphNormals,x.morphColors=y.morphColors,x.morphTargetsCount=y.morphTargetsCount,x.numClippingPlanes=y.numClippingPlanes,x.numIntersection=y.numClipIntersection,x.vertexAlphas=y.vertexAlphas,x.vertexTangents=y.vertexTangents,x.toneMapping=y.toneMapping}function AW(k,y){if(k.length===0)return null;if(k.length===1)return k[0].texture!==null?k[0]:null;w.setFromMatrixPosition(y.matrixWorld);for(let x=0,f=k.length;x<f;x++){let v=k[x];if(v.texture!==null&&v.boundingBox.containsPoint(w))return v}return null}function wW(k,y,x,f,v){if(y.isScene!==!0)y=OJ;g.resetTextureUnits();let E0=y.fog,O0=f.isMeshStandardMaterial||f.isMeshLambertMaterial||f.isMeshPhongMaterial?y.environment:null,G0=h===null?B.outputColorSpace:h.isXRRenderTarget===!0?h.texture.colorSpace:h0.workingColorSpace,L0=f.isMeshStandardMaterial||f.isMeshLambertMaterial&&!f.envMap||f.isMeshPhongMaterial&&!f.envMap,B0=r.get(f.envMap||O0,L0),S0=f.vertexColors===!0&&!!x.attributes.color&&x.attributes.color.itemSize===4,y0=!!x.attributes.tangent&&(!!f.normalMap||f.anisotropy>0),z0=!!x.morphAttributes.position,s0=!!x.morphAttributes.normal,XJ=!!x.morphAttributes.color,YJ=cJ;if(f.toneMapped){if(h===null||h.isXRRenderTarget===!0)YJ=B.toneMapping}let o0=x.morphAttributes.position||x.morphAttributes.normal||x.morphAttributes.color,kJ=o0!==void 0?o0.length:0,R0=T.get(f),PJ=A.state.lights;if(m0===!0){if(b0===!0||k!==e){let JJ=k===e&&f.id===t;Q0.setState(f,k,JJ)}}let d0=!1;if(f.version===R0.__version){if(R0.needsLights&&R0.lightsStateVersion!==PJ.state.version)d0=!0;else if(R0.outputColorSpace!==G0)d0=!0;else if(v.isBatchedMesh&&R0.batching===!1)d0=!0;else if(!v.isBatchedMesh&&R0.batching===!0)d0=!0;else if(v.isBatchedMesh&&R0.batchingColor===!0&&v.colorTexture===null)d0=!0;else if(v.isBatchedMesh&&R0.batchingColor===!1&&v.colorTexture!==null)d0=!0;else if(v.isInstancedMesh&&R0.instancing===!1)d0=!0;else if(!v.isInstancedMesh&&R0.instancing===!0)d0=!0;else if(v.isSkinnedMesh&&R0.skinning===!1)d0=!0;else if(!v.isSkinnedMesh&&R0.skinning===!0)d0=!0;else if(v.isInstancedMesh&&R0.instancingColor===!0&&v.instanceColor===null)d0=!0;else if(v.isInstancedMesh&&R0.instancingColor===!1&&v.instanceColor!==null)d0=!0;else if(v.isInstancedMesh&&R0.instancingMorph===!0&&v.morphTexture===null)d0=!0;else if(v.isInstancedMesh&&R0.instancingMorph===!1&&v.morphTexture!==null)d0=!0;else if(R0.envMap!==B0)d0=!0;else if(f.fog===!0&&R0.fog!==E0)d0=!0;else if(R0.numClippingPlanes!==void 0&&(R0.numClippingPlanes!==Q0.numPlanes||R0.numIntersection!==Q0.numIntersection))d0=!0;else if(R0.vertexAlphas!==S0)d0=!0;else if(R0.vertexTangents!==y0)d0=!0;else if(R0.morphTargets!==z0)d0=!0;else if(R0.morphNormals!==s0)d0=!0;else if(R0.morphColors!==XJ)d0=!0;else if(R0.toneMapping!==YJ)d0=!0;else if(R0.morphTargetsCount!==kJ)d0=!0;else if(!!R0.lightProbeGrid!==A.state.lightProbeGridArray.length>0)d0=!0}else d0=!0,R0.__version=f.version;let vJ=R0.currentProgram;if(d0===!0){if(vJ=m8(f,y,v),C&&f.isNodeMaterial)C.onUpdateProgram(f,vJ,R0)}let oJ=!1,F9=!1,o9=!1,a0=vJ.getUniforms(),UJ=R0.uniforms;if(L.useProgram(vJ.program))oJ=!0,F9=!0,o9=!0;if(f.id!==t)t=f.id,F9=!0;if(R0.needsLights){let JJ=AW(A.state.lightProbeGridArray,v);if(R0.lightProbeGrid!==JJ)R0.lightProbeGrid=JJ,F9=!0}if(oJ||e!==k){if(L.buffers.depth.getReversed()&&k.reversedDepth!==!0)k._reversedDepth=!0,k.updateProjectionMatrix();a0.setValue(j,"projectionMatrix",k.projectionMatrix),a0.setValue(j,"viewMatrix",k.matrixWorldInverse);let R9=a0.map.cameraPosition;if(R9!==void 0)R9.setValue(j,yJ.setFromMatrixPosition(k.matrixWorld));if($J.logarithmicDepthBuffer)a0.setValue(j,"logDepthBufFC",2/(Math.log(k.far+1)/Math.LN2));if(f.isMeshPhongMaterial||f.isMeshToonMaterial||f.isMeshLambertMaterial||f.isMeshBasicMaterial||f.isMeshStandardMaterial||f.isShaderMaterial)a0.setValue(j,"isOrthographic",k.isOrthographicCamera===!0);if(e!==k)e=k,F9=!0,o9=!0}if(R0.needsLights){if(PJ.state.directionalShadowMap.length>0)a0.setValue(j,"directionalShadowMap",PJ.state.directionalShadowMap,g);if(PJ.state.spotShadowMap.length>0)a0.setValue(j,"spotShadowMap",PJ.state.spotShadowMap,g);if(PJ.state.pointShadowMap.length>0)a0.setValue(j,"pointShadowMap",PJ.state.pointShadowMap,g)}if(v.isSkinnedMesh){a0.setOptional(j,v,"bindMatrix"),a0.setOptional(j,v,"bindMatrixInverse");let JJ=v.skeleton;if(JJ){if(JJ.boneTexture===null)JJ.computeBoneTexture();a0.setValue(j,"boneTexture",JJ.boneTexture,g)}}if(v.isBatchedMesh){if(a0.setOptional(j,v,"batchingTexture"),a0.setValue(j,"batchingTexture",v._matricesTexture,g),a0.setOptional(j,v,"batchingIdTexture"),a0.setValue(j,"batchingIdTexture",v._indirectTexture,g),a0.setOptional(j,v,"batchingColorTexture"),v._colorsTexture!==null)a0.setValue(j,"batchingColorTexture",v._colorsTexture,g)}let D9=x.morphAttributes;if(D9.position!==void 0||D9.normal!==void 0||D9.color!==void 0)l0.update(v,x,vJ);if(F9||R0.receiveShadow!==v.receiveShadow)R0.receiveShadow=v.receiveShadow,a0.setValue(j,"receiveShadow",v.receiveShadow);if((f.isMeshStandardMaterial||f.isMeshLambertMaterial||f.isMeshPhongMaterial)&&f.envMap===null&&y.environment!==null)UJ.envMapIntensity.value=y.environmentIntensity;if(UJ.dfgLUT!==void 0)UJ.dfgLUT.value=$G();if(F9){if(a0.setValue(j,"toneMappingExposure",B.toneMappingExposure),R0.needsLights)CW(UJ,o9);if(E0&&f.fog===!0)N0.refreshFogUniforms(UJ,E0);if(N0.refreshMaterialUniforms(UJ,f,F0,Z0,A.state.transmissionRenderTarget[k.id]),R0.needsLights&&R0.lightProbeGrid){let JJ=R0.lightProbeGrid;UJ.probesSH.value=JJ.texture,UJ.probesMin.value.copy(JJ.boundingBox.min),UJ.probesMax.value.copy(JJ.boundingBox.max),UJ.probesResolution.value.copy(JJ.resolution)}g8.upload(j,W$(R0),UJ,g)}if(f.isShaderMaterial&&f.uniformsNeedUpdate===!0)g8.upload(j,W$(R0),UJ,g),f.uniformsNeedUpdate=!1;if(f.isSpriteMaterial)a0.setValue(j,"center",v.center);if(a0.setValue(j,"modelViewMatrix",v.modelViewMatrix),a0.setValue(j,"normalMatrix",v.normalMatrix),a0.setValue(j,"modelMatrix",v.matrixWorld),f.uniformsGroups!==void 0){let JJ=f.uniformsGroups;for(let R9=0,a9=JJ.length;R9<a9;R9++){let H$=JJ[R9];q0.update(H$,vJ),q0.bind(H$,vJ)}}return vJ}function CW(k,y){k.ambientLightColor.needsUpdate=y,k.lightProbe.needsUpdate=y,k.directionalLights.needsUpdate=y,k.directionalLightShadows.needsUpdate=y,k.pointLights.needsUpdate=y,k.pointLightShadows.needsUpdate=y,k.spotLights.needsUpdate=y,k.spotLightShadows.needsUpdate=y,k.rectAreaLights.needsUpdate=y,k.hemisphereLights.needsUpdate=y}function _W(k){return k.isMeshLambertMaterial||k.isMeshToonMaterial||k.isMeshPhongMaterial||k.isMeshStandardMaterial||k.isShadowMaterial||k.isShaderMaterial&&k.lights===!0}if(this.getActiveCubeFace=function(){return n},this.getActiveMipmapLevel=function(){return u},this.getRenderTarget=function(){return h},this.setRenderTargetTextures=function(k,y,x){let f=T.get(k);if(f.__autoAllocateDepthBuffer=k.resolveDepthBuffer===!1,f.__autoAllocateDepthBuffer===!1)f.__useRenderToTexture=!1;T.get(k.texture).__webglTexture=y,T.get(k.depthTexture).__webglTexture=f.__autoAllocateDepthBuffer?void 0:x,f.__hasExternalTextures=!0},this.setRenderTargetFramebuffer=function(k,y){let x=T.get(k);x.__webglFramebuffer=y,x.__useDefaultFramebuffer=y===void 0},this.setRenderTarget=function(k,y=0,x=0){h=k,n=y,u=x;let f=null,v=!1,E0=!1;if(k){let G0=T.get(k);if(G0.__useDefaultFramebuffer!==void 0){L.bindFramebuffer(j.FRAMEBUFFER,G0.__webglFramebuffer),H0.copy(k.viewport),M0.copy(k.scissor),k0=k.scissorTest,L.viewport(H0),L.scissor(M0),L.setScissorTest(k0),t=-1;return}else if(G0.__webglFramebuffer===void 0)g.setupRenderTarget(k);else if(G0.__hasExternalTextures)g.rebindTextures(k,T.get(k.texture).__webglTexture,T.get(k.depthTexture).__webglTexture);else if(k.depthBuffer){let S0=k.depthTexture;if(G0.__boundDepthTexture!==S0){if(S0!==null&&T.has(S0)&&(k.width!==S0.image.width||k.height!==S0.image.height))throw Error("THREE.WebGLRenderer: Attached DepthTexture is initialized to the incorrect size.");g.setupDepthRenderbuffer(k)}}let L0=k.texture;if(L0.isData3DTexture||L0.isDataArrayTexture||L0.isCompressedArrayTexture)E0=!0;let B0=T.get(k).__webglFramebuffer;if(k.isWebGLCubeRenderTarget){if(Array.isArray(B0[y]))f=B0[y][x];else f=B0[y];v=!0}else if(k.samples>0&&g.useMultisampledRTT(k)===!1)f=T.get(k).__webglMultisampledFramebuffer;else if(Array.isArray(B0))f=B0[x];else f=B0;H0.copy(k.viewport),M0.copy(k.scissor),k0=k.scissorTest}else H0.copy(p0).multiplyScalar(F0).floor(),M0.copy(f0).multiplyScalar(F0).floor(),k0=v0;if(x!==0)f=m;if(L.bindFramebuffer(j.FRAMEBUFFER,f))L.drawBuffers(k,f);if(L.viewport(H0),L.scissor(M0),L.setScissorTest(k0),v){let G0=T.get(k.texture);j.framebufferTexture2D(j.FRAMEBUFFER,j.COLOR_ATTACHMENT0,j.TEXTURE_CUBE_MAP_POSITIVE_X+y,G0.__webglTexture,x)}else if(E0){let G0=y;for(let L0=0;L0<k.textures.length;L0++){let B0=T.get(k.textures[L0]);j.framebufferTextureLayer(j.FRAMEBUFFER,j.COLOR_ATTACHMENT0+L0,B0.__webglTexture,x,G0)}}else if(k!==null&&x!==0){let G0=T.get(k.texture);j.framebufferTexture2D(j.FRAMEBUFFER,j.COLOR_ATTACHMENT0,j.TEXTURE_2D,G0.__webglTexture,x)}t=-1},this.readRenderTargetPixels=function(k,y,x,f,v,E0,O0,G0=0){if(!(k&&k.isWebGLRenderTarget)){_0("WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");return}let L0=T.get(k).__webglFramebuffer;if(k.isWebGLCubeRenderTarget&&O0!==void 0)L0=L0[O0];if(L0){L.bindFramebuffer(j.FRAMEBUFFER,L0);try{let B0=k.textures[G0],S0=B0.format,y0=B0.type;if(k.textures.length>1)j.readBuffer(j.COLOR_ATTACHMENT0+G0);if(!$J.textureFormatReadable(S0)){_0("WebGLRenderer.readRenderTargetPixels: renderTarget is not in RGBA or implementation defined format.");return}if(!$J.textureTypeReadable(y0)){_0("WebGLRenderer.readRenderTargetPixels: renderTarget is not in UnsignedByteType or implementation defined type.");return}if(y>=0&&y<=k.width-f&&(x>=0&&x<=k.height-v))j.readPixels(y,x,f,v,c.convert(S0),c.convert(y0),E0)}finally{let B0=h!==null?T.get(h).__webglFramebuffer:null;L.bindFramebuffer(j.FRAMEBUFFER,B0)}}},this.readRenderTargetPixelsAsync=async function(k,y,x,f,v,E0,O0,G0=0){if(!(k&&k.isWebGLRenderTarget))throw Error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");let L0=T.get(k).__webglFramebuffer;if(k.isWebGLCubeRenderTarget&&O0!==void 0)L0=L0[O0];if(L0)if(y>=0&&y<=k.width-f&&(x>=0&&x<=k.height-v)){L.bindFramebuffer(j.FRAMEBUFFER,L0);let B0=k.textures[G0],S0=B0.format,y0=B0.type;if(k.textures.length>1)j.readBuffer(j.COLOR_ATTACHMENT0+G0);if(!$J.textureFormatReadable(S0))throw Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in RGBA or implementation defined format.");if(!$J.textureTypeReadable(y0))throw Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in UnsignedByteType or implementation defined type.");let z0=j.createBuffer();j.bindBuffer(j.PIXEL_PACK_BUFFER,z0),j.bufferData(j.PIXEL_PACK_BUFFER,E0.byteLength,j.STREAM_READ),j.readPixels(y,x,f,v,c.convert(S0),c.convert(y0),0);let s0=h!==null?T.get(h).__webglFramebuffer:null;L.bindFramebuffer(j.FRAMEBUFFER,s0);let XJ=j.fenceSync(j.SYNC_GPU_COMMANDS_COMPLETE,0);return j.flush(),await yZ(j,XJ,4),j.bindBuffer(j.PIXEL_PACK_BUFFER,z0),j.getBufferSubData(j.PIXEL_PACK_BUFFER,0,E0),j.deleteBuffer(z0),j.deleteSync(XJ),E0}else throw Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: requested read bounds are out of range.")},this.copyFramebufferToTexture=function(k,y=null,x=0){let f=Math.pow(2,-x),v=Math.floor(k.image.width*f),E0=Math.floor(k.image.height*f),O0=y!==null?y.x:0,G0=y!==null?y.y:0;g.setTexture2D(k,0),j.copyTexSubImage2D(j.TEXTURE_2D,x,0,0,O0,G0,v,E0),L.unbindTexture()},this.copyTextureToTexture=function(k,y,x=null,f=null,v=0,E0=0){let O0,G0,L0,B0,S0,y0,z0,s0,XJ,YJ=k.isCompressedTexture?k.mipmaps[E0]:k.image;if(x!==null)O0=x.max.x-x.min.x,G0=x.max.y-x.min.y,L0=x.isBox3?x.max.z-x.min.z:1,B0=x.min.x,S0=x.min.y,y0=x.isBox3?x.min.z:0;else{let UJ=Math.pow(2,-v);if(O0=Math.floor(YJ.width*UJ),G0=Math.floor(YJ.height*UJ),k.isDataArrayTexture)L0=YJ.depth;else if(k.isData3DTexture)L0=Math.floor(YJ.depth*UJ);else L0=1;B0=0,S0=0,y0=0}if(f!==null)z0=f.x,s0=f.y,XJ=f.z;else z0=0,s0=0,XJ=0;let o0=c.convert(y.format),kJ=c.convert(y.type),R0;if(y.isData3DTexture)g.setTexture3D(y,0),R0=j.TEXTURE_3D;else if(y.isDataArrayTexture||y.isCompressedArrayTexture)g.setTexture2DArray(y,0),R0=j.TEXTURE_2D_ARRAY;else g.setTexture2D(y,0),R0=j.TEXTURE_2D;L.activeTexture(j.TEXTURE0),L.pixelStorei(j.UNPACK_FLIP_Y_WEBGL,y.flipY),L.pixelStorei(j.UNPACK_PREMULTIPLY_ALPHA_WEBGL,y.premultiplyAlpha),L.pixelStorei(j.UNPACK_ALIGNMENT,y.unpackAlignment);let PJ=L.getParameter(j.UNPACK_ROW_LENGTH),d0=L.getParameter(j.UNPACK_IMAGE_HEIGHT),vJ=L.getParameter(j.UNPACK_SKIP_PIXELS),oJ=L.getParameter(j.UNPACK_SKIP_ROWS),F9=L.getParameter(j.UNPACK_SKIP_IMAGES);L.pixelStorei(j.UNPACK_ROW_LENGTH,YJ.width),L.pixelStorei(j.UNPACK_IMAGE_HEIGHT,YJ.height),L.pixelStorei(j.UNPACK_SKIP_PIXELS,B0),L.pixelStorei(j.UNPACK_SKIP_ROWS,S0),L.pixelStorei(j.UNPACK_SKIP_IMAGES,y0);let o9=k.isDataArrayTexture||k.isData3DTexture,a0=y.isDataArrayTexture||y.isData3DTexture;if(k.isDepthTexture){let UJ=T.get(k),D9=T.get(y),JJ=T.get(UJ.__renderTarget),R9=T.get(D9.__renderTarget);L.bindFramebuffer(j.READ_FRAMEBUFFER,JJ.__webglFramebuffer),L.bindFramebuffer(j.DRAW_FRAMEBUFFER,R9.__webglFramebuffer);for(let a9=0;a9<L0;a9++){if(o9)j.framebufferTextureLayer(j.READ_FRAMEBUFFER,j.COLOR_ATTACHMENT0,T.get(k).__webglTexture,v,y0+a9),j.framebufferTextureLayer(j.DRAW_FRAMEBUFFER,j.COLOR_ATTACHMENT0,T.get(y).__webglTexture,E0,XJ+a9);j.blitFramebuffer(B0,S0,O0,G0,z0,s0,O0,G0,j.DEPTH_BUFFER_BIT,j.NEAREST)}L.bindFramebuffer(j.READ_FRAMEBUFFER,null),L.bindFramebuffer(j.DRAW_FRAMEBUFFER,null)}else if(v!==0||k.isRenderTargetTexture||T.has(k)){let UJ=T.get(k),D9=T.get(y);L.bindFramebuffer(j.READ_FRAMEBUFFER,o),L.bindFramebuffer(j.DRAW_FRAMEBUFFER,p);for(let JJ=0;JJ<L0;JJ++){if(o9)j.framebufferTextureLayer(j.READ_FRAMEBUFFER,j.COLOR_ATTACHMENT0,UJ.__webglTexture,v,y0+JJ);else j.framebufferTexture2D(j.READ_FRAMEBUFFER,j.COLOR_ATTACHMENT0,j.TEXTURE_2D,UJ.__webglTexture,v);if(a0)j.framebufferTextureLayer(j.DRAW_FRAMEBUFFER,j.COLOR_ATTACHMENT0,D9.__webglTexture,E0,XJ+JJ);else j.framebufferTexture2D(j.DRAW_FRAMEBUFFER,j.COLOR_ATTACHMENT0,j.TEXTURE_2D,D9.__webglTexture,E0);if(v!==0)j.blitFramebuffer(B0,S0,O0,G0,z0,s0,O0,G0,j.COLOR_BUFFER_BIT,j.NEAREST);else if(a0)j.copyTexSubImage3D(R0,E0,z0,s0,XJ+JJ,B0,S0,O0,G0);else j.copyTexSubImage2D(R0,E0,z0,s0,B0,S0,O0,G0)}L.bindFramebuffer(j.READ_FRAMEBUFFER,null),L.bindFramebuffer(j.DRAW_FRAMEBUFFER,null)}else if(a0)if(k.isDataTexture||k.isData3DTexture)j.texSubImage3D(R0,E0,z0,s0,XJ,O0,G0,L0,o0,kJ,YJ.data);else if(y.isCompressedArrayTexture)j.compressedTexSubImage3D(R0,E0,z0,s0,XJ,O0,G0,L0,o0,YJ.data);else j.texSubImage3D(R0,E0,z0,s0,XJ,O0,G0,L0,o0,kJ,YJ);else if(k.isDataTexture)j.texSubImage2D(j.TEXTURE_2D,E0,z0,s0,O0,G0,o0,kJ,YJ.data);else if(k.isCompressedTexture)j.compressedTexSubImage2D(j.TEXTURE_2D,E0,z0,s0,YJ.width,YJ.height,o0,YJ.data);else j.texSubImage2D(j.TEXTURE_2D,E0,z0,s0,O0,G0,o0,kJ,YJ);if(L.pixelStorei(j.UNPACK_ROW_LENGTH,PJ),L.pixelStorei(j.UNPACK_IMAGE_HEIGHT,d0),L.pixelStorei(j.UNPACK_SKIP_PIXELS,vJ),L.pixelStorei(j.UNPACK_SKIP_ROWS,oJ),L.pixelStorei(j.UNPACK_SKIP_IMAGES,F9),E0===0&&y.generateMipmaps)j.generateMipmap(R0);L.unbindTexture()},this.initRenderTarget=function(k){if(T.get(k).__webglFramebuffer===void 0)g.setupRenderTarget(k)},this.initTexture=function(k){if(k.isCubeTexture)g.setTextureCube(k,0);else if(k.isData3DTexture)g.setTexture3D(k,0);else if(k.isDataArrayTexture||k.isCompressedArrayTexture)g.setTexture2DArray(k,0);else g.setTexture2D(k,0);L.unbindTexture()},this.resetState=function(){n=0,u=0,h=null,L.reset(),W0.reset()},typeof __THREE_DEVTOOLS__<"u")__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}get coordinateSystem(){return qQ}get outputColorSpace(){return this._outputColorSpace}set outputColorSpace(J){this._outputColorSpace=J;let Q=this.getContext();Q.drawingBufferColorSpace=h0._getDrawingBufferColorSpace(J),Q.unpackColorSpace=h0._getUnpackColorSpace()}}var d6=()=>window.matchMedia("(prefers-reduced-motion: reduce)").matches;function WG(){if(d6())return null;let J=new N$({autoRaf:!0,smoothWheel:!0,lerp:0.09});return window.__omiLenis=J,J}function KG(J){let Q=J.querySelectorAll("[data-hero-word]");if(Q.length<2)return;let $=0;if(Q.forEach((Z,W)=>Z.classList.toggle("is-active",W===0)),d6())return;window.setInterval(()=>{Q[$]?.classList.remove("is-active"),$=($+1)%Q.length,Q[$]?.classList.add("is-active");let Z=J.querySelector("[data-hero-progress]");if(Z)Z.style.width=`${($+1)/Q.length*100}%`},2800)}function HG(J){let Q=J.querySelector("#manifesto");if(!Q)return;let $=()=>{let Z=Q.getBoundingClientRect(),W=window.innerHeight,K=Math.min(1,Math.max(0,1-(Z.bottom-W*0.2)/(Z.height+W*0.4))),H=(1-K)*12;Q.style.setProperty("--manifesto-blur",`${H.toFixed(2)}px`),Q.style.setProperty("--manifesto-opacity",`${(0.35+K*0.65).toFixed(3)}`)};$(),window.addEventListener("scroll",$,{passive:!0})}function VW(J,Q,$=4,Z=220){let W=new Float32Array(Z*3),K=1.15;for(let X=0;X<Z;X++){let U=X/(Z-1),E=U*Math.PI*2*$+Q;W[X*3]=Math.cos(E)*1.15,W[X*3+1]=(U-0.5)*4.2,W[X*3+2]=Math.sin(E)*1.15}let H=new jJ;H.setAttribute("position",new wJ(W,3));let Y=new f8({color:J,size:0.045,transparent:!0,opacity:0.85,depthWrite:!1,sizeAttenuation:!0});return new S6(H,Y)}function YG(J){let Q=J.querySelector("#omi-unifies"),$=J.querySelector("[data-unifies-canvas]"),Z=J.querySelector("[data-unifies-title]");if(!Q||!$)return;if(d6()){$.dataset.fallback="1";return}let W=new rQ({antialias:!0,alpha:!0,powerPreference:"high-performance"});W.setPixelRatio(Math.min(window.devicePixelRatio,2)),$.appendChild(W.domElement);let K=new A6,H=new IJ(42,1,0.1,40);H.position.set(0,0,6.2);let Y=new I9;Y.add(VW("#fffcec",0)),Y.add(VW("#9aa0ff",Math.PI)),K.add(Y);let X=new h6(16777215,0.8);K.add(X);let U=()=>{let{clientWidth:D,clientHeight:M}=$;W.setSize(D,M,!1),H.aspect=D/Math.max(M,1),H.updateProjectionMatrix()};U(),window.addEventListener("resize",U);let E=0,N=(D)=>{let M=Q.getBoundingClientRect(),z=Q.offsetHeight-window.innerHeight,F=Math.min(1,Math.max(0,-M.top/Math.max(z,1)));if(Y.rotation.y=F*Math.PI*2+D*0.00015,Y.rotation.x=Math.sin(F*Math.PI)*0.25,Y.position.y=(F-0.5)*0.4,Z)Z.style.opacity=String(0.25+F*0.75),Z.style.transform=`scale(${(0.92+F*0.08).toFixed(3)})`;W.render(K,H),E=requestAnimationFrame(N)};E=requestAnimationFrame(N),new IntersectionObserver((D)=>{for(let M of D)if(!M.isIntersecting&&E)cancelAnimationFrame(E),E=0;else if(M.isIntersecting&&!E)E=requestAnimationFrame(N)},{rootMargin:"20% 0px"}).observe(Q)}function XG(J){let Q=J.querySelector(".steps-stack");if(!Q)return;let $=[...Q.querySelectorAll(".step-card")];if(!$.length)return;let Z=()=>{let W=Q.getBoundingClientRect(),K=window.innerHeight;$.forEach((H,Y)=>{let X=Y/$.length,U=(K*0.55-W.top)/Math.max(W.height-K*0.2,1),E=1-Math.min(1,Math.abs(U-(X+0.5/$.length))*3),N=(1-Math.max(0,E))*10;H.style.setProperty("--step-blur",`${N.toFixed(2)}px`),H.style.setProperty("--step-scale",`${(0.94+E*0.06).toFixed(3)}`),H.style.setProperty("--step-opacity",`${(0.45+E*0.55).toFixed(3)}`)})};Z(),window.addEventListener("scroll",Z,{passive:!0})}function UG(J){let Q=J.querySelector("[data-query-track]");if(!Q||d6())return;let $=0,Z=()=>{$-=0.35;let W=Q.scrollWidth/2;if(Math.abs($)>=W)$=0;Q.style.transform=`translate3d(${$}px,0,0)`,requestAnimationFrame(Z)};requestAnimationFrame(Z)}function BW(){let J=document.querySelector("[data-computer-stage]");if(!J)return;WG(),KG(J),HG(J),YG(J),XG(J),UG(J)}if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",BW);else BW();
