FROM openjdk:11-jdk-slim as build

WORKDIR /app

# Copy the application files
COPY . .

# Build the application (if you're using Maven)
RUN ./mvnw clean package -DskipTests

# Run stage
FROM openjdk:11-jre-slim

WORKDIR /app

# Copy the built JAR from the build stage
COPY --from=build /app/target/*.jar app.jar

# Expose the port the app runs on
EXPOSE 8080

# Run the application
CMD ["java", "-jar", "app.jar"]