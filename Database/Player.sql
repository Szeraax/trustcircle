CREATE TABLE [dbo].[Player] (
    [Id]     INT           NOT NULL PRIMARY KEY CLUSTERED ([Id] ASC),
    [Game]   INT           NULL,
    [Guild]  VARCHAR (50)  NULL,
    [UserId] VARCHAR (50)  NULL,
    [Name]   VARCHAR (50)  NULL,
    [Key]    VARCHAR (300) NULL,
    CONSTRAINT [FK_Player_Game] FOREIGN KEY ([Game]) REFERENCES [dbo].[Game] ([Id]) ON DELETE CASCADE ON UPDATE CASCADE
);
