FROM nginx:alpine

# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Custom nginx config to listen on 8080
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy static files
COPY app /usr/share/nginx/html

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
