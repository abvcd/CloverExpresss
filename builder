import math
import tf
import tf2_ros
import geometry_msgs.msg
import tf2_geometry_msgs
import numpy as np
from geometry_msgs.msg import Vector3Stamped, Point, PointStamped
import rospy
from clover import srv
from std_srvs.srv import Trigger
from sensor_msgs.msg import Range
from mavros_msgs.srv import CommandBool
from clover.srv import SetLEDEffect

rospy.init_node('flight')

get_telemetry = rospy.ServiceProxy('get_telemetry', srv.GetTelemetry)
navigate = rospy.ServiceProxy('navigate', srv.Navigate)
navigate_global = rospy.ServiceProxy('navigate_global', srv.NavigateGlobal)
set_position = rospy.ServiceProxy('set_position', srv.SetPosition)
set_velocity = rospy.ServiceProxy('set_velocity', srv.SetVelocity)
set_attitude = rospy.ServiceProxy('set_attitude', srv.SetAttitude)
set_rates = rospy.ServiceProxy('set_rates', srv.SetRates)
land = rospy.ServiceProxy('land', Trigger)
arming = rospy.ServiceProxy('mavros/cmd/arming', CommandBool)
set_effect = rospy.ServiceProxy('led/set_effect', SetLEDEffect)

ar = "aruco_101"
tfBuffer = tf2_ros.Buffer()
listener = tf2_ros.TransformListener(tfBuffer)

MAX_ALTITUDE = 3.0
h_chl = 2

def navigate_wait(x=0, y=0, z=0, yaw=float('nan'), speed=0.5, frame_id='aruco_map', auto_arm=False, tolerance=0.2):
    navigate(x=x, y=y, z=z, yaw=yaw, speed=speed, frame_id=frame_id, auto_arm=auto_arm)

    while not rospy.is_shutdown():
        telem = get_telemetry(frame_id='navigate_target')
        if math.sqrt(telem.x ** 2 + telem.y ** 2 + telem.z ** 2) < tolerance:
            break
        rospy.sleep(0.2)

def navigate_wait_fixed(x=0, y=0, z=1.25, yaw=float('nan'), speed=0.5, frame_id='aruco_map', auto_arm=False, tolerance=0.2):
    global platform_found
    navigate(x=x, y=y, z=z, yaw=yaw, speed=speed, frame_id=frame_id, auto_arm=auto_arm)

    while not rospy.is_shutdown():
        platform_found = False
        telem_platform = get_telemetry(frame_id=ar)
        if str(telem_platform.x) != 'nan':
            print(str(telem_platform.x))
            platform_found = True
            set_effect(b=255)
            break

        telem = get_telemetry(frame_id='navigate_target')
        if math.sqrt(telem.x ** 2 + telem.y ** 2 + telem.z ** 2) < tolerance:
            break
        rospy.sleep(0.1)

def range_callback(msg):
    global h_chl
    h_chl = msg.range

def navigate_to_height(z):
    if z > MAX_ALTITUDE:
        z = MAX_ALTITUDE

rospy.Subscriber('rangefinder/range', Range, range_callback)

def get_aruco_pose(frame_id):
    global tfBuffer, listener
    try:
        trans = tfBuffer.lookup_transform(frame_id, ar, rospy.Time())
    except:
        return None
    pnt_l0 = tf2_geometry_msgs.do_transform_point(PointStamped(point=Point(x=0, y=0, z=0)), trans)
    l0 = np.array([pnt_l0.point.x, pnt_l0.point.y, pnt_l0.point.z])
    return l0

def get_body_pose(frame_id): 
    global tfBuffer, listener
    try:
        trans = tfBuffer.lookup_transform(frame_id, "body", rospy.Time())
    except:
        return None
    pnt_l0 = tf2_geometry_msgs.do_transform_point(PointStamped(point=Point(x=0, y=0, z=0)), trans)
    l0 = np.array([pnt_l0.point.x, pnt_l0.point.y, pnt_l0.point.z])
    return l0

def remove_0_vel(vel): 
    if np.linalg.norm(vel[:2]) < 0.045:
        vel[0] = 0
        vel[1] = 0
    return vel


def main():
    z = 1.7
    
    set_effect(r=255)
    navigate_wait(z=z, speed=1, frame_id="body", auto_arm = True)
    rospy.sleep(2)

 
    set_effect(effect="rainbow")

    for marker in ['aruco_23', 'aruco_20', 'aruco_3', 'aruco_0', 'aruco_12']:
        navigate_wait_fixed(frame_id=marker)
        if platform_found:
            break
    set_effect(b=255)
    navigate_wait(x=0, y=0, z=z, speed=1.5, frame_id=ar, yaw=float('nan'), tolerance=0.2)

    FRQ = 100
    r = rospy.Rate(FRQ)
    prev_vel = None
    prev_pa = None
    prev_t = rospy.get_time()
    st_t = rospy.get_time()
    d = 10

    while d > 0.08 or (rospy.get_time() - st_t < 0.5): 
        pb = get_body_pose("aruco_map")
        pa = get_aruco_pose("aruco_map")
        now = rospy.get_time()
        if prev_pa is None:
            if pb is None:
                r.sleep()
                continue
            navigate(x=pb[0], y=pb[1], z=z, speed=1, frame_id="aruco_map")
            set_effect(b=255)
            prev_pa = pa
            prev_t = now
        else:
            if pb is not None:
                d = np.linalg.norm(pb[:2]-pa[:2])
            if pa is not None:
                vel = (pa-prev_pa)/(now-prev_t+0.001)
                vel = np.clip(vel, -0.7, 0.7)

                vel = remove_0_vel(vel)
                if prev_vel is not None:
                    vel = vel*0.9 + prev_vel*0.1

                t = pa[:2] + vel[:2]*(1.0/FRQ)*2.7
                set_position(x=t[0], y=t[1], z=z, frame_id="aruco_map")
                prev_pa = pa.copy()
                prev_vel = vel.copy()
                prev_t = now
            else:
                navigate(x=pb[0], y=pb[1], z=z, frame_id="aruco_map")
                print("NO pa and vel")

        r.sleep()

    set_effect(g=255)
    z_st = 1.5

    st_t = rospy.get_time()
    z_vel = 0.5

    Z = z_st
    r = rospy.Rate(50)

    while h_chl > 0.09:
        pb = get_body_pose("aruco_map")
        pa = get_aruco_pose("aruco_map")
        now = rospy.get_time()
        if prev_pa is None:
            set_position(x=0, y=0, z=-0.01, frame_id="body")
            print("NO prev_pa")
            prev_pa = pa
            prev_t = now
        else:
            if pb is not None:
                d = np.linalg.norm(pb[:2]-pa[:2])
            if pa is not None:
                if np.linalg.norm(pa - prev_pa) < 0.0001 and prev_vel is not None:
                    vel = prev_vel.copy()*0.97
                else:
                    vel = (pa-prev_pa)/(now-prev_t+0.000025)
                if h_chl > 0.5:
                    vel = np.clip(vel, -0.49, 0.49)
                else:
                    vel = np.clip(vel, -0.3, 0.3)

                vel = remove_0_vel(vel)
                if np.linalg.norm(vel[:2]) < 0.02 and d <= 0.07:
                    Z = -(rospy.get_time()-st_t)*(0.7) + z_st
                else:
                    Z = -(rospy.get_time()-st_t)*z_vel + z_st

                t = pa[:2] + vel[:2]*(1.0/FRQ)*2.2
                set_position(x=t[0], y=t[1], z=Z, frame_id="aruco_map")
                prev_pa = pa.copy()
                print("Z = ", Z)
                prev_vel = vel.copy()
                prev_t = now
            else:
                set_position(x=0, y=0, z=-0.01, frame_id="body")
                print("NO pa and vel")

        r.sleep()
    if h_chl < 0.09:
        arming(False)

if __name__ == '__main__':
    main()
