#version 300 es
precision highp float;

in vec2 aVertexPosition;  // Changed from vec4 to vec2 since points are 2D
uniform float lat_center;
uniform float lon_center;
uniform float zoom;
uniform float aspect;

void main() {
  vec2 position = aVertexPosition;
  
  // Project coordinates relative to center
  position.y = (position.y - lat_center) * aspect * zoom;
  position.x = (position.x - lon_center) * zoom;
  
  gl_Position = vec4(position, 0.0, 1.0);
  gl_PointSize = 2.0;  // Increased point size for better visibility
}