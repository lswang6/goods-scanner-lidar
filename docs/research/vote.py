import numpy as np, os, sys, json
from PIL import Image
sys.path.insert(0,os.path.dirname(__file__)); from hull import load
def rect(xz,k):
    best=None
    for a in np.radians(np.arange(0,90,1.0)):
        R=np.array([[np.cos(a),np.sin(a)],[-np.sin(a),np.cos(a)]]); q=np.sort(xz@R.T,0); e=q[-1-k]-q[k]+0.005
        if best is None or e[0]*e[1]<best[0]: best=(e[0]*e[1],e)
    return sorted(best[1],reverse=True)
vox=0.005
for d in sys.argv[1:]:
    ix,F=load(d); seed=np.array(ix['lockSeed']); est=json.load(open(d+'/scan.json'))['estimate']; fl=est['planeY']
    views=[]
    for fr in F:
        p=f"{d}/images/{fr['t']:.6f}.jpg.mask.pgm"
        if fr['phase']!=1 or not os.path.exists(p): continue
        m=np.array(Image.open(p))>0; K=fr['K'].reshape(3,3); s=m.shape[1]/fr['res'][0]
        views.append((m,K[0,0]*s,K[1,1]*s,(K[2,0]+.5)*s-.5,(K[2,1]+.5)*s-.5,fr['T'].reshape(4,4).T))
    c=np.array(est['center'])[[0,2]]
    xs=np.arange(c[0]-0.35,c[0]+0.35,vox); zs=np.arange(c[1]-0.35,c[1]+0.35,vox); ys=np.arange(fl+vox/2,fl+0.45,vox)
    X,Y,Z=np.meshgrid(xs,ys,zs,indexing='ij'); G=np.stack([X.ravel(),Y.ravel(),Z.ravel()],1).astype(np.float32)
    seen=np.zeros(len(G),np.int32); out=np.zeros(len(G),np.int32)
    for m,fx,fy,cx,cy,T in views:
        h,w=m.shape; Pc=(G-T[:3,3])@T[:3,:3]; dz=-Pc[:,2]
        uu=np.round(Pc[:,0]*fx/np.maximum(dz,1e-6)+cx).astype(int); vv=np.round(-Pc[:,1]*fy/np.maximum(dz,1e-6)+cy).astype(int)
        ins=(dz>0.05)&(uu>=0)&(uu<w)&(vv>=0)&(vv<h)
        seen[ins]+=1; o=np.zeros(len(G),bool); o[ins]=~m[vv[ins],uu[ins]]; out+=o
    res=[]
    for frac in (1.0,0.95,0.9):
        keep=(seen>=(len(views)+1)//2)&(out<=np.floor((1-frac)*seen)); H=keep.reshape(len(xs),len(ys),len(zs))
        if est['shape']=='box':
            fi=np.argwhere(H[:,:6,:].any(1))
        else:
            fi=np.argwhere(H.any(1))
        L,W=rect(np.stack([xs[fi[:,0]],zs[fi[:,1]]],1),int(len(fi)*0.005))
        res.append(f"{frac:.2f}: {100*L:5.1f} x {100*W:5.1f}")
    print(f"{os.path.basename(d)} {est['shape']:8s} " + " | ".join(res), flush=True)
