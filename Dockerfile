# Stage 1: Build the Angular application
# FROM node:20-slim AS build
FROM node:22-slim AS build
RUN npm install -g npm@11.6.0

WORKDIR /app

# Copy package.json and package-lock.json
# COPY package.json ./
COPY package.json package-lock.json ./

# I am not creating a package-lock.json, so I will run npm install
# and it will be generated. In a real world scenario, it should be
# part of the repository.
# RUN npm install
RUN npm ci

# Copy the rest of the application files
COPY . .

# Build the application
RUN npm run build

# Stage 2: Serve the application from Nginx
FROM nginx:1.25-alpine

# Copy the built application from the build stage
COPY --from=build /app/dist/gemini-angular-app/browser /usr/share/nginx/html

# Copy the Nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose port 8080
EXPOSE 8080

# Run the entrypoint script
ENTRYPOINT ["/entrypoint.sh"]

# The CMD will be executed by the entrypoint script
CMD ["nginx", "-g", "daemon off;"]
