# Visual hull from LiDAR-derived silhouettes (depth pixels inside the object's LiDAR cylinder) vs from Vision masks,
# same poses: separates mask error from pose error.
import numpy as np, os, sys
from PIL import Image
sys.path.insert(0,os.path.dirname(__file__)); from hull import load, cam
def rect(xz,k):
    best=None
    for a in np.radians(np.arange(0,90,1.0)):
        R=np.array([[np.cos(a),np.sin(a)],[-np.sin(a),np.cos(a)]]); q=np.sort(xz@R.T,0); e=q[-1-k]-q[k]+0.005
        if best is None or e[0]*e[1]<best[0]: best=(e[0]*e[1],e)
    return sorted(best[1],reverse=True)
def hull(views, c, y0, vox=0.005, R=0.3, Hm=0.45):
    xs=np.arange(c[0]-R,c[0]+R,vox); zs=np.arange(c[1]-R,c[1]+R,vox); ys=np.arange(y0+vox/2,y0+Hm,vox)
    X,Y,Z=np.meshgrid(xs,ys,zs,indexing='ij'); G=np.stack([X.ravel(),Y.ravel(),Z.ravel()],1).astype(np.float32)
    keep=np.ones(len(G),bool); seen=np.zeros(len(G),np.int32)
    for m,fx,fy,cx,cy,T in views:
        h,w=m.shape; idx=np.nonzero(keep)[0]; Pc=(G[idx]-T[:3,3])@T[:3,:3]; dz=-Pc[:,2]
        uu=np.round(Pc[:,0]*fx/np.maximum(dz,1e-6)+cx).astype(int); vv=np.round(-Pc[:,1]*fy/np.maximum(dz,1e-6)+cy).astype(int)
        ins=(dz>0.05)&(uu>=0)&(uu<w)&(vv>=0)&(vv<h); carve=np.zeros(len(idx),bool); carve[ins]=~m[vv[ins],uu[ins]]
        seen[idx[ins]]+=1; keep[idx[carve]]=False
    keep&=seen>=(len(views)+1)//2; H=keep.reshape(len(xs),len(ys),len(zs))
    best=(0,0,0)
    for j in range(0,len(ys),4):
        fi=np.argwhere(H[:,j:j+4,:].any(1))
        if len(fi)<20: continue
        L,W=rect(np.stack([xs[fi[:,0]],zs[fi[:,1]]],1),int(len(fi)*0.005))
        if L*W>best[0]*best[1]: best=(L,W,ys[j]-y0)
    return best
d=sys.argv[1]; cxz=np.array([float(sys.argv[2]),float(sys.argv[3])]); floor=float(sys.argv[4]); rad=float(sys.argv[5])
ix,F=load(d); w,h=ix['width'],ix['height']; u=np.tile(np.arange(w),h); v=np.repeat(np.arange(h),w)
lv=[];vv_=[]
for i in range(len(F)):
    if F[i]['phase']!=1: continue
    fx,fy,cx,cy,T=cam(F[i],w,h); dd=F[i]['sm'].astype(np.float32)
    Q=np.stack([(u-cx)*dd/fx,-(v-cy)*dd/fy,-dd],1)@T[:3,:3].T+T[:3,3]
    ok=np.isfinite(dd)&(dd>0)
    m=ok&(np.hypot(Q[:,0]-cxz[0],Q[:,2]-cxz[1])<rad)&(Q[:,1]>floor+0.015)
    lv.append((m.reshape(h,w),fx,fy,cx,cy,T))
    p=f"{d}/images/{F[i]['t']:.6f}.jpg.mask.pgm"
    if os.path.exists(p):
        mm=np.array(Image.open(p))>0; K=F[i]['K'].reshape(3,3); s=mm.shape[1]/F[i]['res'][0]
        vv_.append((mm,K[0,0]*s,K[1,1]*s,(K[2,0]+.5)*s-.5,(K[2,1]+.5)*s-.5,T))
for name,views in [('LiDAR silhouettes',lv),('Vision masks',vv_)]:
    L,W,y=hull(views,cxz,floor); print(f"   {name:18s} ({len(views)} views): widest {100*L:.1f} x {100*W:.1f} at {100*y:.0f} cm")
