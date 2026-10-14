-- SPDX-License-Identifier: GPL-2.0-or-later
-- Read-only visible-bitmap controller. No memory writes or ROM changes.
-- Output is ordinary joystick/fire input, saved as a static RTL replay fixture.
local policy={}
local target, last_player, move, aim= nil,nil,0,0
local old_bullets={}
local dodge_until,dodge_move=0,0
local function components(program)
    local ram=program:read_range(0x4000,0x5fff,8)
    local points={}
    for i=1,#ram do
        local b=ram:byte(i)
        if b~=0 then
            local y=(i-1)//32; local x=((i-1)%32)*8
            if y>=16 and y<240 and x<232 then
                for bit=0,7 do if (b&(1<<bit))~=0 then points[y*256+x+bit]=true end end
            end
        end
    end
    local keys={}; for key in pairs(points) do keys[#keys+1]=key end; table.sort(keys)
    local groups={}
    for _,key in ipairs(keys) do
        if points[key] then
            local queue={key}; points[key]=nil
            local n,head,sx,sy,minx,miny,maxx,maxy=0,1,0,0,256,256,0,0
            while head<=#queue do
                local k=queue[head]; head=head+1; local x,y=k%256,k//256
                n=n+1; sx=sx+x; sy=sy+y
                minx=math.min(minx,x); maxx=math.max(maxx,x)
                miny=math.min(miny,y); maxy=math.max(maxy,y)
                for dy=-1,1 do for dx=-1,1 do
                    local near=(y+dy)*256+x+dx
                    if x+dx>=0 and x+dx<232 and points[near] then points[near]=nil; queue[#queue+1]=near end
                end end
            end
            groups[#groups+1]={x=sx/n,y=sy/n,n=n,w=maxx-minx+1,h=maxy-miny+1}
        end
    end
    return groups
end
local function distance(a,b) return (a.x-b.x)^2+(a.y-b.y)^2 end
local function position(e,p)
    local best,best_cost
    -- Project the player onto each legal firing ray. A fixed diagonal offset
    -- cannot reach the centre bandits within the player's movement bounds.
    for dx=-1,1 do for dy=-1,1 do if dx~=0 or dy~=0 then
        local low,high=20,256
        local function bound(origin,direction,a,b)
            if direction==0 then if origin<a or origin>b then high=-1 end
            else
                local x,y=(a-origin)/direction,(b-origin)/direction
                low=math.max(low,math.min(x,y)); high=math.min(high,math.max(x,y))
            end
        end
        bound(e.x,dx,64,160);bound(e.y,dy,64,192)
        if high>=low then
            local t=((p.x-e.x)*dx+(p.y-e.y)*dy)/(dx*dx+dy*dy)
            t=math.max(low,math.min(high,t))
            local q={x=e.x+dx*t,y=e.y+dy*t}; local blocked=false
            for _,f in ipairs({{32,128,12,12},{192,128,12,12},{112,44,12,8},{112,212,12,10}}) do
                -- Segment versus the barricade rectangle, with a shot margin.
                local enter,leave=0,t
                for axis=1,2 do
                    local o=axis==1 and e.x or e.y;local d=axis==1 and dx or dy
                    local a,b=f[axis]-f[axis+2]-2,f[axis]+f[axis+2]+2
                    if d==0 then if o<a or o>b then leave=-1 end
                    else local a1,b1=(a-o)/d,(b-o)/d;enter=math.max(enter,math.min(a1,b1));leave=math.min(leave,math.max(a1,b1)) end
                end
                if leave>=enter then blocked=true end
            end
            local cost=distance(q,p)
            if not blocked and (not best_cost or cost<best_cost) then best,best_cost=q,cost end
        end
    end
    end end
    return best or {x=p.x,y=p.y}
end
function policy.step(frame,program)
    if frame<880 then return end
    local detail
    if frame%4==0 then
        local groups=components(program); local players,enemies={},{}
        for _,g in ipairs(groups) do
            -- The Sheriff's arm/gun can extend beyond a 20-pixel box. Its
            -- connected body is larger than either half of a bandit sprite.
            if g.n>=50 and g.w<=32 and g.h<=32 and g.x>40 and g.x<184 and g.y>52 and g.y<204 then players[#players+1]=g end
            if g.w<=20 and g.h<=20 then
                if g.n>=24 and g.n<=85 then
                    local fence=false
                    for _,f in ipairs({{x=32,y=128},{x=192,y=128},{x=112,y=44},{x=112,y=212}}) do if distance(g,f)<225 then fence=true end end
                    if not fence then enemies[#enemies+1]=g end
                end
            end
        end
        -- The two halves of each edge bandit are adjacent bitmap components.
        -- Merge them so the shot targets the centre of the entire sprite.
        local merged={}
        for _,e in ipairs(enemies) do
            local found
            for _,m in ipairs(merged) do if distance(e,m)<144 then found=m;break end end
            if found then
                local n=found.n+e.n
                found.x=(found.x*found.n+e.x*e.n)/n;found.y=(found.y*found.n+e.y*e.n)/n;found.n=n
            else merged[#merged+1]={x=e.x,y=e.y,n=e.n} end
        end
        enemies=merged
        local p,pcost
        for _,g in ipairs(players) do
            local cost=distance(g,last_player or {x=112,y=128})
            if not pcost or cost<pcost then p,pcost=g,cost end
        end
        move,aim=0,0
        if p then
            last_player=p
            local actual_enemies={}
            for _,e in ipairs(enemies) do if distance(e,p)>324 then actual_enemies[#actual_enemies+1]=e end end
            enemies=actual_enemies
            local chosen,ccost
            for _,e in ipairs(enemies) do
                local q=position(e,p)
                local cost=distance(q,p)+(target and distance(e,target)<400 and -100000 or 0)
                if not ccost or cost<ccost then chosen,ccost=e,cost end
            end
            target=chosen
            if target then
                local q=position(target,p); local dx,dy=q.x-p.x,q.y-p.y
                if math.abs(dx)>math.abs(dy) and math.abs(dx)>2 then move=dx>0 and 4 or 8
                elseif math.abs(dy)>2 then move=dy>0 and 1 or 2 end
                local tx,ty=target.x-p.x,target.y-p.y
                -- Cabinet orientation: up/down are native +/-X, right/left +/-Y.
                if math.abs(tx)>math.abs(ty)*2.4 then aim=tx>0 and 64 or 128
                elseif math.abs(ty)>math.abs(tx)*2.4 then aim=ty>0 and 16 or 32
                else aim=(tx>0 and 64 or 128)|(ty>0 and 16 or 32) end
            end
            -- Evade only a small visible projectile moving towards the player.
            -- Own outgoing shots have a positive dot product and are ignored.
            local bullets={}
            for _,g in ipairs(groups) do
                if g.n<=8 and g.w<=4 and g.h<=4 and g.x>=60 and g.x<=164 and g.y>=60 and g.y<=196 then bullets[#bullets+1]=g end
            end
            if frame>=dodge_until then
                for _,b in ipairs(bullets) do
                    local previous,cost
                    for _,o in ipairs(old_bullets) do local d=distance(b,o);if not cost or d<cost then previous,cost=o,d end end
                    if previous and cost>1 and cost<625 then
                        local vx,vy=b.x-previous.x,b.y-previous.y
                        local rx,ry=b.x-p.x,b.y-p.y;local dot=rx*vx+ry*vy
                        local eta=-dot/(vx*vx+vy*vy)
                        local closest=(rx+vx*eta)^2+(ry+vy*eta)^2
                        if dot<0 and eta>=0 and eta<=4 and rx*rx+ry*ry<2304 and closest<100 then
                            if math.abs(vx)>math.abs(vy) then
                                local positive=p.y>=b.y
                                if p.y>180 then positive=false elseif p.y<76 then positive=true end
                                dodge_move=positive and 1 or 2
                            else
                                local positive=p.x>=b.x
                                if p.x>148 then positive=false elseif p.x<76 then positive=true end
                                dodge_move=positive and 4 or 8
                            end
                            dodge_until=frame+16;break
                        end
                    end
                end
            end
            old_bullets=bullets
            if frame<dodge_until then move=dodge_move end
            detail={math.floor(p.x),math.floor(p.y),target and math.floor(target.x) or -1,target and math.floor(target.y) or -1,#enemies,move|aim}
        else
            target=nil; last_player=nil
            old_bullets={};dodge_until=0
            detail={-1,-1,-1,-1,#enemies,0}
        end
    end
    return move|aim,0,(frame%8<4 and aim~=0) and 1 or 0,255,detail
end
return policy
