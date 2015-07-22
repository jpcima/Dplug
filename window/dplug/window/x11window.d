/**
* Copyright: Copyright Auburn Sounds 2015 and later.
* License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
* Authors:   Guillaume Piolat
*/
module dplug.window.x11window;

import core.stdc.config;
import core.stdc.stdlib;

import ae.utils.graphics;

import gfm.math;

import dplug.window.window;


version(linux)
{
    import x11.X;
    import x11.Xutil;
    import x11.Xlib;
    import x11.keysymdef;

    final class X11Window : IWindow
    {
    private:
        bool _terminated = false;
        bool _initialized = false;
        
        IWindowListener _listener;
        
        int _width = 0;
        int _height = 0;
        ubyte* _buffer = null;

        Window _window;    
        Display* _display;
        Screen* _screen;  
        int _screenNumber;
        GC _gc;
        XImage* _bufferImage;

        XEvent _event;

        enum scanLineAlignment = 4;

    public:

        this(void* parentWindow, IWindowListener listener, int width, int height)
        {
            _listener = listener;
            _display = XOpenDisplay(null);
            if (_display is null)
                throw new Exception("Cannot open display");

            _screen = DefaultScreenOfDisplay(_display);
            _screenNumber = DefaultScreen(_display);

            Window parent;
            int x, y;
            if (parentWindow is null)
            {
                x = 0;
                y = 0;
                parent = RootWindow(_display, _screenNumber);
            }
            else
            {
                parent = cast(Window)(parentWindow);
                x = (WidthOfScreen(_screen) - width) / 2;
                y = (HeightOfScreen(_screen) - height) / 2;
            }

            c_long eventMask = 
                KeyPressMask |
                KeyReleaseMask |
      /*          ButtonPressMask,
                ButtonReleaseMask,
                EnterWindowMask,
                LeaveWindowMask,
                PointerMotionMask,
                PointerMotionHintMask,
                Button1MotionMask,
                Button2MotionMask,
                Button3MotionMask,
                Button4MotionMask,
                Button5MotionMask,
                ButtonMotionMask,
                KeymapStateMask, */
                ExposureMask |
/*                VisibilityChangeMask,
                StructureNotifyMask,
                ResizeRedirectMask,
                SubstructureNotifyMask,
                SubstructureRedirectMask,
                FocusChangeMask,
                PropertyChangeMask,
                ColormapChangeMask,
                OwnerGrabButtonMask*/
                0 ;
            

            auto black = BlackPixel(_display, _screenNumber);

            _window = XCreateSimpleWindow(_display, parent, x, y, width, height, 1, black, black);
            XSelectInput(_display, _window, eventMask);
            XMapWindow(_display, _window);
            
            _gc = XCreateGC(_display, _window, 0, null);  // create the Graphics Context

            XFlush(_display); // Flush all pending requests to the X server.

            _initialized = true;

            XSynchronize(_display, true);
        }

        ~this()
        {
            close();
        }

        void close()
        {
            if (_initialized)
            {
                _initialized = false;
                XDestroyImage(_bufferImage);
                XFreeGC(_display, _gc);
                XDestroyWindow(_display, _window);
                XCloseDisplay(_display); 
            }
        }
        
        override void terminate()
        {
            close();
        }
        
        // Implements IWindow
        override void waitEventAndDispatch()
        {
            XNextEvent(_display, &_event);
            dispatchEvent(&_event);
        }

        override bool terminated()
        {
            return _terminated;
        }

        override void debugOutput(string s)
        {
            import std.stdio;
            writeln(s); // TODO: something better
        }

        override uint getTimeMs()
        {            
            import core.sys.posix.time;
            timespec time;
            clock_gettime(CLOCK_REALTIME, &time);
            return cast(uint)(time.tv_sec * 1000 + time.tv_nsec / 1_000_000);
        }
    private:

        void dispatchEvent(XEvent* event)
        {
            switch (event.type)
            {
                case Expose: 
                    handleXExposeEvent(&event.xexpose);
                    break;

                case KeyPress: 
                    handleXKeyEvent(&event.xkey, false);
                    break;

                case KeyRelease: 
                    handleXKeyEvent(&event.xkey, true);
                    break;

                default:
                  // ignore
            }
        }

        void handleXKeyEvent(XKeyEvent* event, bool release)
        {
            if (release)
                _listener.onKeyUp(translateToKey(event));
            else   
                _listener.onKeyDown(translateToKey(event));          
        }      

        Key translateToKey(XKeyEvent* event)
        {
            char[32] buffer;
            KeySym keysym;
            XLookupString(event, buffer.ptr, cast(int)buffer.length, &keysym, null);

            switch(keysym)
            {
                case XK_space: return Key.space;
                case XK_Up: return Key.upArrow;
                case XK_Down: return Key.downArrow;
                case XK_Left: return Key.leftArrow;
                case XK_Right: return Key.rightArrow;
                case XK_KP_0: return Key.digit0;
                case XK_KP_1: return Key.digit1;
                case XK_KP_2: return Key.digit2;
                case XK_KP_3: return Key.digit3;
                case XK_KP_4: return Key.digit4;
                case XK_KP_5: return Key.digit5;
                case XK_KP_6: return Key.digit6;
                case XK_KP_7: return Key.digit7;
                case XK_KP_8: return Key.digit8;
                case XK_KP_9: return Key.digit9;
                case XK_Return: return Key.enter;
                case XK_Escape: return Key.escape;
                default:
                    return Key.unsupported;
            }
        }

        void handleXExposeEvent(XExposeEvent* event)
        {
            // Get window size
            updateSizeIfNeeded();

            ImageRef!RGBA wfb;
            wfb.w = _width;
            wfb.h = _height;
            wfb.pitch = byteStride(_width);
            wfb.pixels = cast(RGBA*)_buffer;

            bool swapRB = false;
            _listener.onDraw(wfb, swapRB);

            box2i areaToRedraw = box2i(0, 0, _width, _height);                        
            box2i[] areasToRedraw = (&areaToRedraw)[0..1];
            swapBuffers(wfb, areasToRedraw);
        }

        // given a width, how long in bytes should scanlines be
        int byteStride(int width)
        {
            int widthInBytes = width * 4;
            return (widthInBytes + (scanLineAlignment - 1)) & ~(scanLineAlignment-1);
        }

        /// Returns: true if window size changed.
        bool updateSizeIfNeeded()
        {
            XWindowAttributes attrib;
            Status status = XGetWindowAttributes(_display, _window, &attrib);
            if (status == 0)
                throw new Exception("XGetWindowAttributes failed");

            int newWidth = attrib.width;
            int newHeight = attrib.height;

            // only do something if the client size has changed
            if (newWidth != _width || newHeight != _height)
            {
                // Extends buffer
                if (_buffer != null)
                {
                    // calls free on _buffer
                    XDestroyImage(_bufferImage);
                    //free(_buffer);
                    _buffer = null;
                }

                size_t sizeNeeded = byteStride(newWidth) * newHeight;
                _buffer = cast(ubyte*) malloc(sizeNeeded);                

                _bufferImage = XCreateImage(_display, 
                                            attrib.visual,
                                            32, 
                                            ZPixmap, 
                                            0,  // offset
                                            cast(char*)_buffer, 
                                            _width, 
                                            _height, 
                                            scanLineAlignment * 8,
                                            byteStride(newWidth));
                _width = newWidth;
                _height = newHeight;
                _listener.onResized(_width, _height);

                return true;
            }
            else
                return false;
        }

        void swapBuffers(ImageRef!RGBA wfb, box2i[] areasToRedraw)
        {         
            foreach(box2i area; areasToRedraw)
            {
                int x = area.min.x;
                int y = area.min.y;                
                XPutImage(_display, _window, _gc, _bufferImage, x, y, x, y, area.width, area.height);
            }
            XSync(_display, False);           
        }
    }
}


/+

// Receiving commands from a window
interface IWindowListener
{
    /// Called on mouse click.
    /// Returns: true if the event was handled.
    bool onMouseClick(int x, int y, MouseButton mb, bool isDoubleClick, MouseState mstate);

    /// Called on mouse button release
    /// Returns: true if the event was handled.
    bool onMouseRelease(int x, int y, MouseButton mb, MouseState mstate);

    /// Called on mouse wheel movement
    /// Returns: true if the event was handled.
    bool onMouseWheel(int x, int y, int wheelDeltaX, int wheelDeltaY, MouseState mstate);

    /// Called on mouse movement (might not be within the window)
    void onMouseMove(int x, int y, int dx, int dy, MouseState mstate);


    /// Recompute internally what needs be done for the next onDraw.
    /// This function MUST be called before calling `onDraw` and `getDirtyRectangle`.
    /// This method exists to allow the Window to recompute these draw lists less.
    /// And because cache invalidation was easier on user code than internally in the UI.
    void recomputeDirtyAreas();

    /// Returns: Minimal rectangle that contains dirty UIELement in UI + their graphical extent.
    ///          Empty box if nothing to update.
    /// recomputeDirtyAreas() MUST have been called before.
    box2i getDirtyRectangle();

    /// Returns: true if a control must be redrawn.
    bool isUIDirty();

    /// Called whenever mouse capture was canceled (ALT + TAB, SetForegroundWindow...)
    void onMouseCaptureCancelled();

    /// Must be called periodically (ideally 60 times per second but this is not mandatory).
    /// `time` must refer to the window creation time.
    void onAnimate(double dt, double time);
}
+/